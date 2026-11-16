'use strict';

const PORTS = { web: 8095, staff: 18795, firestore: 8389, firestoreSocket: 9390, auth: 9399, hub: 4620, logging: 4720 };

delete process.env.GCLOUD_PROJECT;
process.env.FIRESTORE_EMULATOR_HOST = `127.0.0.1:${PORTS.firestore}`;
process.env.FIREBASE_AUTH_EMULATOR_HOST = `127.0.0.1:${PORTS.auth}`;
process.env.PLATFORM_EMULATOR_PROJECTS = 'cos40005,hardware-client-sales';

const fs = require('node:fs');
const http = require('node:http');
const net = require('node:net');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');
const E = require('../e2e/lib/emulator.cjs');
const platform = require('../e2e/lib/platform.cjs');
const directory = require('../e2e/lib/platform_api.cjs');
const staff = require('../e2e/lib/staff.cjs');
const { putPerson } = require('../e2e/lib/seed.cjs');
const demo = require('./seed_control_centre_demo.cjs');

const DEMO = process.argv.includes('--demo');

const ROOT = platform.ROOT;
const OWNER_EMAIL = 'owner@scoot.test';
const WEB_URL = `http://127.0.0.1:${PORTS.web}`;
const ADMIN_DIR = path.join(ROOT, 'admin_dashboard');
const BUILD_NAME = 'web_control_local_signin';
const BUILD_DIR = path.join(ADMIN_DIR, 'build', BUILD_NAME);
const WORK_DIR = path.join(ROOT, 'qa_artifacts', 'control_centre_local');
const EMULATOR_PROJECT = directory.PLATFORM_PROJECT;
const COMPANIES = [
  { project: 'cos40005', legalName: 'Everrise Supermarket', planId: 'PROFESSIONAL' },
  { project: 'hardware-client-sales', legalName: 'Hardware Client', planId: 'STANDARD' },
];

const running = { emulators: null, staff: null, web: null, codes: null };

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function killTree(child) {
  if (!child || child.exitCode !== null || !child.pid) return;
  if (process.platform === 'win32') spawnSync('taskkill', ['/PID', String(child.pid), '/T', '/F']);
  else child.kill('SIGTERM');
}

let stopping = false;
async function shutdown(code) {
  if (stopping) return;
  stopping = true;
  console.log('\nStopping the Control Centre...');
  if (running.codes) clearInterval(running.codes);
  if (running.web) running.web.close();
  killTree(running.emulators && running.emulators.child);
  if (running.staff) await Promise.race([running.staff.stop(), sleep(3000)]);
  process.exit(code);
}

const portFree = (port) => new Promise((resolve) => {
  const probe = net.createServer();
  probe.once('error', () => resolve(false));
  probe.listen(port, '127.0.0.1', () => probe.close(() => resolve(true)));
});

function newestSourceTime(entry) {
  const stat = fs.statSync(entry);
  if (!stat.isDirectory()) return stat.mtimeMs;
  return fs.readdirSync(entry).reduce((latest, name) => Math.max(latest, newestSourceTime(path.join(entry, name))), 0);
}

function ensureBuild() {
  const index = path.join(BUILD_DIR, 'index.html');
  const sources = ['lib', 'web', 'pubspec.yaml', 'pubspec.lock'].map((name) => path.join(ADMIN_DIR, name)).filter((entry) => fs.existsSync(entry));
  if (fs.existsSync(index) && fs.statSync(index).mtimeMs >= Math.max(...sources.map(newestSourceTime))) return;
  console.log('Building the Control Centre. This takes a few minutes after a code change.');
  const result = spawnSync('flutter', ['build', 'web', '--release', '--no-web-resources-cdn',
    '-t', 'lib/control_centre/main.dart', '--output', path.join('build', BUILD_NAME),
    '--dart-define=USE_FIREBASE_EMULATOR=true', '--dart-define=FIREBASE_EMULATOR_HOST=127.0.0.1',
    `--dart-define=FIREBASE_AUTH_EMULATOR_PORT=${PORTS.auth}`, `--dart-define=STAFF_FIREBASE_PROJECT_ID=${EMULATOR_PROJECT}`], {
    cwd: ADMIN_DIR, stdio: 'inherit', shell: process.platform === 'win32',
  });
  if (result.status !== 0) throw new Error('The Control Centre build failed.');
}

function startEmulators() {
  fs.mkdirSync(WORK_DIR, { recursive: true });
  const config = path.join(WORK_DIR, 'firebase.json');
  fs.writeFileSync(config, JSON.stringify({
    emulators: {
      firestore: { host: '127.0.0.1', port: PORTS.firestore, websocketPort: PORTS.firestoreSocket },
      auth: { host: '127.0.0.1', port: PORTS.auth },
      hub: { host: '127.0.0.1', port: PORTS.hub },
      logging: { host: '127.0.0.1', port: PORTS.logging },
      ui: { enabled: false },
      singleProjectMode: false,
    },
  }, null, 2));
  const child = spawn(process.execPath, [path.join(ROOT, 'node_modules', 'firebase-tools', 'lib', 'bin', 'firebase.js'),
    'emulators:start', '--only', 'firestore,auth', '--project', EMULATOR_PROJECT, '--config', config], {
    cwd: WORK_DIR, stdio: ['ignore', 'pipe', 'pipe'],
  });
  let log = '';
  const remember = (chunk) => { log = (log + chunk).slice(-4000); };
  child.stdout.on('data', remember);
  child.stderr.on('data', remember);
  return { child, tail: () => log };
}

async function waitForUrl(url, emulators) {
  const deadline = Date.now() + 180000;
  for (;;) {
    try {
      if ((await fetch(url)).ok) return;
    } catch {}
    if (emulators.child.exitCode !== null || Date.now() > deadline) {
      throw new Error(`The Firebase emulators did not start:\n${emulators.tail()}`);
    }
    await sleep(500);
  }
}

function seedPlatform(key) {
  const records = COMPANIES.map(({ project, legalName }) => ({ record: { ...platform.baseRecord(project), legalName }, key }));
  directory.seedDirectory([key], records);
  records.forEach(({ record }, index) => {
    directory.planAdmin([key], [
      { op: 'catalogue' },
      { op: 'usage' },
      { op: 'subscribe', planId: COMPANIES[index].planId, status: 'active', billingInterval: 'monthly' },
    ], record.tenantId);
    console.log(`  ${record.legalName}: ${COMPANIES[index].planId} package, record status ${record.status}`);
  });
  return records.map(({ record }) => record);
}

function describeFailure(error) {
  const cause = error && error.cause ? ` (${error.cause.code || error.cause.message})` : '';
  return `${error.message}${cause}`;
}

async function startStaffApiWithRetry(start) {
  for (let attempt = 1; ; attempt += 1) {
    try {
      return await start();
    } catch (error) {
      if (attempt === 3 || running.emulators.child.exitCode !== null) {
        throw new Error(`The staff API did not start: ${describeFailure(error)}`);
      }
      console.log(`  The staff API is not ready yet (${describeFailure(error)}). Trying again...`);
      await sleep(3000);
    }
  }
}

async function activateCompany(service, tenantId) {
  const call = async (method, resource, body, idempotencyKey) => {
    const response = await fetch(`${service.url}/staff/v1/${resource}`, {
      method,
      headers: { 'Content-Type': 'application/json', ...service.headers('owner'),
        ...(idempotencyKey ? { 'Idempotency-Key': idempotencyKey } : {}) },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const result = await response.json();
    if (!response.ok) {
      throw new Error(`${resource}: ${response.status} ${JSON.stringify(result)}`);
    }
    return result;
  };
  const draft = await call('POST', `companies/${tenantId}/invoices`, {}, `demo-invoice-${tenantId}`);
  const invoice = await call('POST', `invoices/${draft.invoiceId}/issue`);
  const payment = await call('POST', `companies/${tenantId}/payments`, {
    amountMinor: invoice.outstandingMinor, currency: 'MYR', externalReference: `DEMO/BANK-${tenantId}`,
    invoiceId: invoice.invoiceId, receivedAt: `${new Date().toISOString().slice(0, 19)}Z`, reason: 'Local demo payment',
  }, `demo-payment-${tenantId}`);
  const active = await call('PUT', `companies/${tenantId}/lifecycle`, {
    state: 'active', expectedRevision: 0, paymentEntryId: payment.entryId, reason: 'Local demo company', ticket: null,
  }, `demo-active-${tenantId}`);
  if (active.status && active.status !== 'completed') {
    throw new Error(`lifecycle: ${JSON.stringify(active)}`);
  }
}

function forward(req, res, target, headers) {
  const upstream = http.request({
    hostname: target.hostname, port: target.port, method: req.method, path: req.url,
    headers: { ...req.headers, ...headers },
  }, (reply) => {
    res.writeHead(reply.statusCode, reply.headers);
    reply.pipe(res);
  });
  upstream.on('error', (error) => {
    if (!res.headersSent) res.writeHead(502, { 'Content-Type': 'text/plain' });
    res.end(`Control Centre local proxy error: ${error.message}`);
  });
  req.pipe(upstream);
}

async function startWeb(service, site) {
  const siteTarget = new URL(site.url);
  const staffTarget = new URL(service.url);
  const server = http.createServer((req, res) => {
    if (req.url.startsWith('/staff/')) {
      forward(req, res, staffTarget, {});
    } else {
      forward(req, res, siteTarget, {});
    }
  });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(PORTS.web, '127.0.0.1', resolve);
  });
  return server;
}

function watchSignInCodes(file) {
  let seen = fs.existsSync(file) ? fs.statSync(file).size : 0;
  return setInterval(() => {
    if (!fs.existsSync(file)) return;
    const size = fs.statSync(file).size;
    if (size <= seen) return;
    const handle = fs.openSync(file, 'r');
    const chunk = Buffer.alloc(size - seen);
    fs.readSync(handle, chunk, 0, chunk.length, seen);
    fs.closeSync(handle);
    seen = size;
    for (const line of chunk.toString('utf8').split(/\r?\n/).filter(Boolean)) {
      try {
        const mail = JSON.parse(line);
        const code = mail.request && mail.request.params && mail.request.params.code;
        const to = ((mail.request && mail.request.to) || []).map((entry) => entry.email).join(', ');
        if (code) console.log(`Sign-in code for ${to}: ${code}`);
        const invite = mail.request && mail.request.params && mail.request.params.inviteUrl;
        const hash = typeof invite === 'string' ? invite.indexOf('#') : -1;
        if (hash >= 0) console.log(`Invitation for ${to}: open ${WEB_URL}/${invite.slice(hash)}`);
      } catch {}
    }
  }, 1000);
}

function openBrowser(url) {
  if (process.platform === 'win32') spawn('cmd', ['/c', 'start', '', url], { stdio: 'ignore', detached: true }).unref();
  else spawn(process.platform === 'darwin' ? 'open' : 'xdg-open', [url], { stdio: 'ignore', detached: true }).unref();
}

async function main() {
  for (const port of Object.values(PORTS)) {
    if (!(await portFree(port))) {
      throw new Error(`Port ${port} is already in use. Close the other Control Centre window and start again.`);
    }
  }
  ensureBuild();

  console.log('Starting the local Firebase emulators...');
  running.emulators = startEmulators();
  await waitForUrl(`http://127.0.0.1:${PORTS.firestore}/`, running.emulators);
  await waitForUrl(`http://127.0.0.1:${PORTS.auth}/`, running.emulators);

  const key = platform.ensureKey();
  if (DEMO) {
    console.log('Starting the staff API...');
    running.staff = await startStaffApiWithRetry(() => demo.startDemoStaffApi(key, { port: PORTS.staff, browserSignIn: true }));
    console.log('Loading the demo story through the staff API. This takes a few minutes...');
    await demo.seedDemo({ service: running.staff, key });
  } else {
    console.log('Seeding the demo data...');
    await putPerson(E.client('cos40005'), { email: OWNER_EMAIL, name: 'Cassie', role: 'admin', code: 'ADM-001', branch: 'B1' });
    const records = seedPlatform(key);

    console.log('Starting the staff API...');
    running.staff = await startStaffApiWithRetry(() => staff.startStaffApi(key, { port: PORTS.staff, roleEmails: { owner: OWNER_EMAIL }, browserSignIn: true }));
    for (const record of records) {
      try {
        await activateCompany(running.staff, record.tenantId);
        console.log(`  ${record.legalName}: payment recorded, lifecycle active`);
      } catch (error) {
        console.log(`  ${record.legalName}: lifecycle not activated (${error.message})`);
      }
    }
  }

  const site = await staff.serveBuild(BUILD_DIR);
  running.web = await startWeb(running.staff, site);
  console.log(`
Control Centre: ${WEB_URL}`);
  const people = DEMO ? demo.ROLE_EMAILS : { owner: OWNER_EMAIL };
  console.log('Sign in with one of these accounts:');
  for (const [role, email] of Object.entries(people)) console.log(`  ${role}: ${email}`);
  console.log(`  Password for every account: ${E.PASSWORD}`);
  console.log('Each emailed sign-in code is printed below. Data is local and resets on every start.');
  console.log('Press Ctrl+C to stop.\n');
  running.codes = watchSignInCodes(directory.mailEnv().PLATFORM_MAIL_STUB_FILE);
  if (!process.argv.includes('--no-open')) openBrowser(WEB_URL);
}

for (const signal of ['SIGINT', 'SIGTERM', 'SIGHUP', 'SIGBREAK']) process.on(signal, () => shutdown(0));
main().catch(async (error) => {
  console.error(`\n${error.message}`);
  await shutdown(1);
});
