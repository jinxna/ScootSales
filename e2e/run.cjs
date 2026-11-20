'use strict';

const fs = require('node:fs');

const FLUTTER_ERROR = /FLUTTER_ERROR:|EXCEPTION CAUGHT BY|Another exception was thrown|has already been listened to|pageerror:/;
const path = require('node:path');
const E = require('./lib/emulator.cjs');
const { startApps } = require('./lib/apps.cjs');
const { launchBrowser, newSession } = require('./lib/browser.cjs');
const { seedBase, ACCOUNTS } = require('./lib/seed.cjs');
const platform = require('./lib/platform.cjs');
const directory = require('./lib/platform_api.cjs');

const FLOWS_DIR = path.join(__dirname, 'flows');
const FLOW_TIMES_FILE = path.join(__dirname, 'flow_times.json');
const knownBugs = [];

const OTHER_RUNNERS = {
  signin: ['cc_signin', 'control_centre_tour', 'first_use_empty', 'p1_billing', 'solo_owner', 'v4_control_centre', 'onboarding_new_company', 'onboarding_byo_company'],
  'tenant-routing': ['company_api_central', 'hardware_adoption', 'scout_company_record'],
};
const RUNNER = process.env.E2E_RUNNER || (process.env.E2E_TENANT_ROUTING === '1' ? 'tenant-routing' : 'default');

function runnerOf(file) {
  const name = file.replace(/\.spec\.cjs$/, '');
  return Object.keys(OTHER_RUNNERS).find((runner) => OTHER_RUNNERS[runner].includes(name)) || 'default';
}

function shardOf(files) {
  const spec = process.env.E2E_SHARD;
  if (!spec) return files;
  const match = /^([1-9]\d*)\/([1-9]\d*)$/.exec(spec);
  const index = match && Number(match[1]);
  const total = match && Number(match[2]);
  if (!match || index > total) throw new Error('E2E_SHARD must look like 2/5, got ' + spec);
  const recorded = JSON.parse(fs.readFileSync(FLOW_TIMES_FILE, 'utf8'));
  const known = Object.values(recorded).sort((a, b) => a - b);
  const fallback = known.length ? known[Math.floor(known.length / 2)] : 60;
  const secondsOf = (file) => recorded[file.replace(/\.spec\.cjs$/, '')] ?? fallback;
  const shards = Array.from({ length: total }, () => ({ seconds: 0, files: [] }));
  const longestFirst = [...files].sort((a, b) => secondsOf(b) - secondsOf(a) || a.localeCompare(b));
  for (const file of longestFirst) {
    const lightest = shards.reduce((best, shard) => (shard.seconds < best.seconds ? shard : best));
    lightest.seconds += secondsOf(file);
    lightest.files.push(file);
  }
  return shards[index - 1].files.sort();
}

function namedFlows(names) {
  return names.split(',').map((name) => {
    const file = `${name.trim()}.spec.cjs`;
    if (!fs.existsSync(path.join(FLOWS_DIR, file))) throw new Error('E2E_FLOWS names a flow that does not exist: ' + name);
    return file;
  });
}

function listFlows(filter) {
  if (process.env.E2E_FLOWS && !filter) return namedFlows(process.env.E2E_FLOWS);
  const files = fs.readdirSync(FLOWS_DIR)
    .filter((f) => f.endsWith('.spec.cjs') && (filter ? f.includes(filter) : runnerOf(f) === RUNNER))
    .sort();
  return shardOf(files);
}

async function runFlow(file, { db, urls: appUrls, browser }) {
  const urls = { ...appUrls };
  const flow = require(path.join(FLOWS_DIR, file));
  const flowName = flow.name || file.replace(/\.spec\.cjs$/, '');
  const outDir = path.join(E.OUTPUT_DIR, flowName);
  const sessions = [];
  const t0 = Date.now();
  let stepNo = 0;
  const stepResults = [];

  await db.reset();
  const seed = await seedBase(db);

  let platformApi = null;
  if (flow.platformApi !== false) {
    const key = platform.ensureKey();
    await directory.resetDirectory();
    directory.seedDirectory([key], [{ record: platform.harnessRecord(), key }]);
    if (flow.seedPlan !== false) directory.seedHarnessPlan([key]);
    platformApi = await directory.startPlatformApi({ origin: [urls.admin, urls.mobile], keys: [key], mail: flow.platformMail === true, scheduler: flow.platformScheduler === true });
  }

  const t = {
    db, urls, accounts: ACCOUNTS, seed, platformApi,
    async session(app, opts = {}) {
      const s = await newSession(browser, { name: opts.name || app, ...opts });
      s.app = app;
      s.url = urls[app];
      sessions.push(s);
      return s;
    },
    async step(name, fn) {
      stepNo += 1;
      const started = Date.now();
      try {
        const result = await fn();
        console.log(`  ok   ${stepNo}. ${name} (${Date.now() - started} ms)`);
        stepResults.push({ step: stepNo, name, result: 'ok', ms: Date.now() - started });
        return result;
      } catch (error) {
        console.log(`  FAIL ${stepNo}. ${name}: ${error.message.split('\n')[0]}`);
        stepResults.push({ step: stepNo, name, result: 'fail', ms: Date.now() - started, error: error.message.split('\n')[0] });
        error.step = `${stepNo}. ${name}`;
        throw error;
      }
    },
    async expectedFailure(name, info, fn) {
      stepNo += 1;
      const started = Date.now();
      let error = null;
      try {
        await fn();
      } catch (e) {
        error = e;
      }
      if (!error) {
        const message = `KNOWN_BUG step unexpectedly passed (${info.bug}). The bug looks fixed: turn this expectedFailure into a normal t.step.`;
        console.log(`  FAIL ${stepNo}. ${name}: ${message}`);
        const failed = new Error(message);
        failed.step = `${stepNo}. ${name}`;
        throw failed;
      }
      console.log(`  KNOWN_BUG ${stepNo}. ${name} (${Date.now() - started} ms): ${info.bug}`);
      stepResults.push({ step: stepNo, name, result: 'known_bug', ms: Date.now() - started, bug: info.bug });
      console.log(`            still failing with: ${error.message.split('\n')[0].slice(0, 200)}`);
      await collectEvidence(`KNOWN_BUG-${stepNo}`);
      fs.writeFileSync(path.join(outDir, `KNOWN_BUG-${stepNo}-error.txt`), `${info.bug}\n${info.ref || ''}\n${error.stack || error}\n`);
      knownBugs.push(`${flowName}: ${stepNo}. ${name}`);
    },
    async shot(session, label) {
      fs.mkdirSync(outDir, { recursive: true });
      await session.page.screenshot({ path: path.join(outDir, `${session.app}-${label}.png`) });
    },
  };

  async function collectEvidence(prefix) {
    fs.mkdirSync(outDir, { recursive: true });
    const lines = [];
    for (const [i, s] of sessions.entries()) {
      await s.page.screenshot({ path: path.join(outDir, `${prefix}-${i}-${s.app}.png`) }).catch(() => null);
      const text = await s.page.evaluate(() => Array.from(document.querySelectorAll('flt-semantics'))
        .map((n) => (n.getAttribute('aria-label') || n.textContent || '').trim()).filter(Boolean).join('\n')).catch(() => '');
      fs.writeFileSync(path.join(outDir, `${prefix}-${i}-${s.app}-semantics.txt`), text);
      lines.push(...s.logs);
      if (s.blocked.length) lines.push(`[${s.app}] blocked external requests:`, ...s.blocked.map((u) => '  ' + u));
    }
    fs.writeFileSync(path.join(outDir, `${prefix === 'FAILED' ? '' : prefix + '-'}console.log`), lines.join('\n'));
  }
  t.collectEvidence = collectEvidence;

  console.log(`\nFLOW ${flowName}`);
  let failure = null;
  try {
    await flow.run(t);
  } catch (error) {
    failure = error;
  }

  if (!failure) {
    const errors = sessions.flatMap((s) => s.logs).filter((line) => FLUTTER_ERROR.test(line));
    if (errors.length) {
      failure = new Error(`Flutter error on the page:\n${errors.slice(0, 3).join('\n')}`);
      failure.step = 'console check';
    }
  }

  if (failure) {
    await collectEvidence('FAILED');
    fs.writeFileSync(path.join(outDir, 'error.txt'), `${failure.step || ''}\n${failure.stack || failure}\n`);
  }
  if (!failure && process.env.E2E_KEEP_CONSOLE === '1') await collectEvidence('KEPT');
  const blockedHosts = new Set(sessions.flatMap((s) => s.blocked.map((u) => new URL(u).hostname)));
  if (blockedHosts.size) console.log(`  (hermetic: answered 404 for external hosts: ${[...blockedHosts].join(', ')})`);
  for (const s of sessions) await s.context.close().catch(() => null);
  if (platformApi) await platformApi.stop();
  console.log(`${failure ? 'FAILED' : 'PASSED'} ${flowName} (${((Date.now() - t0) / 1000).toFixed(1)} s)`);
  fs.mkdirSync(outDir, { recursive: true });
  fs.writeFileSync(path.join(outDir, 'result.json'), JSON.stringify({
    flow: flowName, passed: !failure, filtered: Boolean(process.argv[2] || process.env.E2E_FILTER), failedStep: failure ? failure.step || '' : null,
    seconds: Number(((Date.now() - t0) / 1000).toFixed(1)), finishedAt: new Date().toISOString(),
    steps: stepResults, screenshots: fs.readdirSync(outDir).filter((f) => f.endsWith('.png')).sort(),
  }, null, 2));
  return !failure;
}

(async () => {
  const filter = process.argv[2] || process.env.E2E_FILTER;
  const files = listFlows(filter);
  if (!files.length) throw new Error('no flows match ' + (filter || '*'));
  fs.rmSync(E.OUTPUT_DIR, { recursive: true, force: true });
  fs.mkdirSync(E.OUTPUT_DIR, { recursive: true });

  const db = E.client();
  const apps = await startApps();
  const browser = await launchBrowser();
  const results = [];
  try {
    for (const file of files) results.push([file, await runFlow(file, { db, urls: apps.urls, browser })]);
  } finally {
    await browser.close();
    await apps.close();
  }
  const failed = results.filter(([, ok]) => !ok);
  console.log(`\n=== E2E: ${results.length - failed.length}/${results.length} flows passed ===`);
  if (knownBugs.length) console.log(`known bugs still open (${knownBugs.length}):\n  - ${knownBugs.join('\n  - ')}`);
  process.exit(failed.length ? 1 : 0);
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
