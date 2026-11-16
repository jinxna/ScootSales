'use strict';
const fs = require('node:fs');
const path = require('node:path');
const { initializeTestEnvironment } = require('@firebase/rules-unit-testing');
const fx = require('./identity_audit_fixtures.cjs');
const support = require('./rules_test_support.cjs');
const cases = require('./budget_guard_cases.cjs');

const out = process.argv[2] || '-';
const FLOOR_UNITS = 14;
const EXCEPTIONS_EXPIRE = '2026-12-31';
const LINKED_EXCEPTIONS = [
  { name: /^route publish batch \(plan \+ publication key\) \(supervisor\)$/, units: 2 },
  { name: /^stop (completed|skipped) batch \(final, closes (active|paused) session\)$/, units: 6 },
  { name: /^tracking_controls update \(supervisor\)$/, units: 8 },
  { name: /^stop (completed|skipped) batch \(non-final\)$/, units: 10 },
  { name: /^tracking_controls update \(admin\)$/, units: 10 },
];
const RULES = fs.readFileSync(
  process.env.PROBE_RULES || path.join(__dirname, '..', 'admin_dashboard', 'firestore.rules'),
  'utf8',
);
const U = support.users;

function floorFor(shape, name) {
  if (shape !== 'linked') return FLOOR_UNITS;
  const exception = LINKED_EXCEPTIONS.find((entry) => entry.name.test(name));
  return exception ? exception.units : FLOOR_UNITS;
}

async function runGroup(kind, shape, units, group, rows) {
  const env = await initializeTestEnvironment({
    projectId: 'demo-fyp-a',
    firestore: { rules: fx.padRules(RULES, units) },
  });
  await env.clearFirestore();
  support.setTestEnv(env);
  if (kind === 'suite') {
    await support.seed();
    for (const user of [U.salesman, U.admin, U.supervisor, U.branchManager, U.otherSalesman]) await support.reshape(user, shape);
  } else {
    await env.withSecurityRulesDisabled((c) => fx.seedAuditActors(c.firestore(), shape));
  }
  for (const c of group) {
    support.setTestEnv(env);
    if (c.prep) await c.prep(env);
    const uid = kind === 'fx' ? fx.AUDIT_ACTORS[c.actorKey].uid : c.actor.uid;
    const db = env.authenticatedContext(uid, support.signedInToken()).firestore();
    let ok = true;
    let err = '';
    try {
      await c.run(db);
    } catch (e) {
      ok = false;
      err = String(e && e.message).replace(/\s+/g, ' ').slice(0, 160);
    }
    support.cleanupContexts();
    rows.push({ shape, name: c.name, units, ok, err });
    if (!ok) console.error(`FAIL [${shape}] ${c.name} at ${units} padding units: ${err}`);
  }
  await env.cleanup();
}

(async () => {
  if (new Date().toISOString().slice(0, 10) > EXCEPTIONS_EXPIRE) {
    console.error(`The linked-profile exceptions in budget_guard.cjs expired on ${EXCEPTIONS_EXPIRE}. Remove them (RULE-01) or renew them with a reason.`);
    process.exit(1);
  }
  const all = [...cases.phone.map((c) => ({ kind: 'suite', ...c })), ...cases.dash.map((c) => ({ kind: 'suite', ...c })), ...cases.fxCases];
  const rows = [];
  for (const kind of ['suite', 'fx']) {
    for (const shape of fx.SHAPES) {
      const applicable = all.filter((c) => c.kind === kind && !c.measureOnly && (c.shapes || fx.SHAPES).includes(shape) && c.actor !== null);
      const byUnits = new Map();
      for (const c of applicable) {
        const units = floorFor(shape, c.name);
        if (!byUnits.has(units)) byUnits.set(units, []);
        byUnits.get(units).push(c);
      }
      for (const [units, group] of byUnits) await runGroup(kind, shape, units, group, rows);
    }
  }
  const failed = rows.filter((r) => !r.ok);
  if (out !== '-') fs.writeFileSync(out, JSON.stringify({ floorUnits: FLOOR_UNITS, rows }, null, 2));
  if (failed.length) {
    console.error(`\nRULES EXPRESSION-BUDGET GUARD FAILED: ${failed.length} of ${rows.length} client paths no longer keep their required padding units of headroom (${FLOOR_UNITS} units, about ${FLOOR_UNITS * 7} expressions, unless listed in LINKED_EXCEPTIONS).`);
    process.exitCode = 1;
  } else {
    console.log(`Rules expression-budget guard passed: ${rows.length} client paths keep at least ${FLOOR_UNITS} padding units of headroom (linked-profile exceptions excepted).`);
  }
})().catch((e) => { console.error(e); process.exit(1); });
