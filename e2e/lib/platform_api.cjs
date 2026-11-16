'use strict';

const crypto = require('node:crypto');
const { spawn, spawnSync } = require('node:child_process');
const E = require('./emulator.cjs');
const platform = require('./platform.cjs');
const fs = require('node:fs');
const path = require('node:path');
const { STUB_FILE } = require('./mail_sink.cjs');

const PLATFORM_PROJECT = 'demo-scoot-platform';
const HARNESS_TENANT = process.env.E2E_FIREBASE_TARGET === 'hardware' ? 't_hardware01' : 't_cos40005';
const INVITE_SECRET = crypto.randomBytes(32).toString('base64url');

function platformEnv(keys) {
  const { firestoreHost, authHost } = E.requireEmulators();
  return {
    ...process.env,
    PYTHONWARNINGS: 'ignore',
    FIRESTORE_EMULATOR_HOST: firestoreHost,
    FIREBASE_AUTH_EMULATOR_HOST: authHost,
    PLATFORM_PROJECT_ID: PLATFORM_PROJECT,
    PLATFORM_PUBLIC_KEYS: platform.publicKeysText(...keys),
    PLATFORM_COMPANY_LOOKUP_LIMIT_PER_HOUR: '100000',
  };
}

const resetDirectory = () => E.client(PLATFORM_PROJECT).reset();

function seedDirectory(keys, items) {
  const seeds = items.map(({ key }) => `${key.keyId}=${key.seed}`);
  platform.python(['e2e/lib/platform_seed.py'], {
    input: JSON.stringify({ project: PLATFORM_PROJECT, records: items.map(({ record, key, issuedAt, ttlDays }) => ({ record, keyId: key.keyId, issuedAt, ttlDays })) }),
    env: { ...platformEnv(keys), PLATFORM_SIGNING_KEYS: [...new Set(seeds)].join(',') },
  });
}

function planAdmin(keys, steps, tenantId = HARNESS_TENANT) {
  const seeds = keys.map((key) => `${key.keyId}=${key.seed}`);
  const out = platform.python(['e2e/lib/plan_admin.py'], {
    input: JSON.stringify({ platformProject: PLATFORM_PROJECT, tenantId, steps }),
    env: {
      ...platformEnv(keys),
      PLATFORM_SIGNING_KEYS: [...new Set(seeds)].join(','),
      PLATFORM_EMULATOR_PROJECTS: 'cos40005,hardware-client-sales',
    },
  });
  return JSON.parse(out.trim().split(/\r?\n/).pop());
}

function seedHarnessPlan(keys) {
  const basic = process.env.E2E_EDITION === 'basic';
  const unlimited = { salesmen: null, supervisors: null, managers: null, products: null };
  const planId = basic ? 'E2EBASIC' : 'INTERNAL';
  return planAdmin(keys, [
    { op: 'catalogue' },
    ...(basic ? [{ op: 'private_plan', planId, limits: unlimited }] : []),
    { op: 'subscribe', planId, reseed: true },
    { op: 'usage' },
  ]);
}

const MAIL_INVITE_URL = 'https://dashboard.scootsales.test/invite';
const MAIL_SENDER = 'noreply@scootsales.test';
const MAIL_WEBHOOK_SECRET = 'e2e-brevo-webhook-secret-0123456789';
const MAIL_STAFF_DOMAIN = 'example.test';

const schedulerEnv = (key) => ({
  PLATFORM_SCHEDULER_ENABLED: 'true',
  PLATFORM_SCHEDULER_POLL_SECONDS: '1',
  PLATFORM_SCHEDULER_PRICE_CHECK_SECONDS: '2',
  PLATFORM_SCHEDULER_ACCOUNT_DELETION_SECONDS: '2',
  PLATFORM_SIGNING_KEY_ID: key.keyId,
  PLATFORM_SIGNING_KEY: key.seed,
});

const templateIds = () => {
  const catalogue = JSON.parse(fs.readFileSync(path.join(platform.ROOT, 'platform_service', 'mail_templates', 'templates.json'), 'utf8'));
  return Object.fromEntries(Object.keys(catalogue).map((name, index) => [name, index + 1]));
};

const mailEnv = () => ({
  PLATFORM_SCHEDULER_MAIL_SECONDS: '2',
  PLATFORM_MAIL_ENABLED: 'true',
  PLATFORM_MAIL_TRANSPORT: 'stub',
  PLATFORM_MAIL_STUB_FILE: STUB_FILE,
  PLATFORM_BREVO_TEMPLATE_IDS: JSON.stringify(templateIds()),
  PLATFORM_MAIL_SENDER: MAIL_SENDER,
  PLATFORM_INVITE_URL: MAIL_INVITE_URL,
  PLATFORM_INVITE_SECRET: INVITE_SECRET,
  PLATFORM_BREVO_WEBHOOK_SECRET: MAIL_WEBHOOK_SECRET,
});

async function startPlatformApi({ origin, keys, mail = false, scheduler = false }) {
  const child = spawn(platform.PYTHON, [
    '-m', 'uvicorn', 'platform_service.app:create_app', '--factory',
    '--host', '127.0.0.1', '--port', String(platform.PLATFORM_API_PORT), '--log-level', 'warning', '--timeout-keep-alive', '120',
  ], {
    cwd: platform.ROOT,
    env: {
      ...platformEnv(keys),
      PLATFORM_CLIENT_CORS_ORIGINS: [].concat(origin).join(','),
      PLATFORM_INVITE_SECRET: INVITE_SECRET,
      PLATFORM_EMULATOR_PROJECTS: 'cos40005,hardware-client-sales',
      PLATFORM_SIGNING_KEY_ID: keys[0].keyId,
      PLATFORM_SIGNING_KEY: keys[0].seed,
      ...(mail || scheduler ? schedulerEnv(keys[0]) : {}),
      ...(mail ? { ...mailEnv(), PLATFORM_STAFF_DOMAINS: MAIL_STAFF_DOMAIN } : {}),
    },
    stdio: ['ignore', 'pipe', 'pipe'],
    windowsHide: true,
  });
  let output = '';
  child.stdout.on('data', (d) => { output += d; });
  child.stderr.on('data', (d) => { output += d; });
  let exited = false;
  child.on('exit', () => { exited = true; });

  const deadline = Date.now() + 30000;
  for (;;) {
    if (exited) throw new Error(`platform API exited early:
${output}`);
    try {
      if ((await fetch(`${platform.PLATFORM_API_URL}/health`)).ok) break;
    } catch (error) { }
    if (Date.now() > deadline) {
      stopProcess(child);
      throw new Error(`platform API did not start within 30 s:
${output}`);
    }
    await new Promise((r) => setTimeout(r, 250));
  }
  return {
    url: platform.PLATFORM_API_URL,
    stop: async () => stopProcess(child),
  };
}

function stopProcess(child) {
  if (child.exitCode !== null || child.pid === undefined) return;
  if (process.platform === 'win32') spawnSync('taskkill', ['/PID', String(child.pid), '/T', '/F'], { windowsHide: true });
  else child.kill('SIGTERM');
}

module.exports = { mailEnv, MAIL_INVITE_URL, MAIL_SENDER, MAIL_WEBHOOK_SECRET, PLATFORM_PROJECT, HARNESS_TENANT, resetDirectory, seedDirectory, planAdmin, seedHarnessPlan, startPlatformApi };
