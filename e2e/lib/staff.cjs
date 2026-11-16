'use strict';

const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');
const B = require('./browser.cjs');
const E = require('./emulator.cjs');
const platform = require('./platform.cjs');
const directory = require('./platform_api.cjs');

const STAFF_PORT = 18791;
const STAFF_ROLE_EMAILS = {
  owner: 'e2e.owner@example.test',
  operator: 'e2e.operator@example.test',
  support: 'e2e.support@example.test',
};

async function prepareLogins(emails) {
  const platformDb = E.client(directory.PLATFORM_PROJECT);
  const uids = {};
  for (const email of emails) {
    const user = await platformDb.ensureUser(email, email.split('@')[0]);
    const verified = await fetch(`${platformDb.authBase}/accounts:update?key=fake-api-key`, {
      method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: 'Bearer owner', Connection: 'close' },
      body: JSON.stringify({ localId: user.uid, emailVerified: true }),
    });
    if (!verified.ok) throw new Error(`could not verify ${email}: ${verified.status} ${await verified.text()}`);
    uids[email] = user.uid;
  }
  const probe = await fetch(`${platformDb.authBase}/accounts:signInWithPassword?key=fake-api-key`, {
    method: 'POST', headers: { 'Content-Type': 'application/json', Connection: 'close' },
    body: JSON.stringify({ email: emails[0], password: E.PASSWORD, returnSecureToken: true }),
  });
  const audience = JSON.parse(Buffer.from((await probe.json()).idToken.split('.')[1], 'base64url').toString()).aud;
  if (audience !== directory.PLATFORM_PROJECT) {
    throw new Error(`The Auth emulator signs tokens for ${audience}. Run this flow with: npm run e2e:signin`);
  }
  return uids;
}

function seedSessions(emails, roleEmails, uids = {}) {
  const roles = Object.fromEntries(Object.values(emails).map((email) => [
    email, Object.entries(roleEmails).find(([, value]) => value === email)?.[0] ?? null]));
  const out = platform.python(['e2e/lib/staff_session.py'], {
    input: JSON.stringify({ project: directory.PLATFORM_PROJECT, roles, uids }),
    env: { ...process.env, PYTHONWARNINGS: 'ignore', PLATFORM_PROJECT_ID: directory.PLATFORM_PROJECT },
  });
  return JSON.parse(out.trim().split(/\r?\n/).pop());
}

async function startStaffApi(key, { extraEmails = {}, port = STAFF_PORT, roleEmails = STAFF_ROLE_EMAILS, browserSignIn = false, scheduler = browserSignIn, e2eReaders = false } = {}) {
  const emails = { ...roleEmails, ...extraEmails };
  const uids = browserSignIn ? await prepareLogins(Object.values(emails)) : {};
  const url = `http://127.0.0.1:${port}`;
  const factory = e2eReaders ? ['--app-dir', path.join('e2e', 'lib'), 'staff_app:create_app'] : ['platform_service.app:create_app'];
  const child = spawn(platform.PYTHON, ['-m', 'uvicorn', ...factory, '--factory',
    '--host', '127.0.0.1', '--port', String(port), '--log-level', 'warning', '--timeout-keep-alive', '120'], {
    cwd: platform.ROOT,
    env: { ...process.env, PYTHONUTF8: '1', PYTHONUNBUFFERED: '1', PYTHONWARNINGS: 'ignore', PLATFORM_PROJECT_ID: directory.PLATFORM_PROJECT,
      PLATFORM_SIGNING_KEY_ID: key.keyId, PLATFORM_SIGNING_KEY: key.seed,
      PLATFORM_PUBLIC_KEYS: platform.publicKeysText(key),
      PLATFORM_STAFF_DOMAINS: [...new Set([...Object.values(emails).map((email) => email.split('@')[1]),
        ...(process.env.PLATFORM_STAFF_DOMAINS || '').split(',').map((domain) => domain.trim().toLowerCase()).filter(Boolean)])].join(','),
      ...(browserSignIn ? { ...directory.mailEnv(), PLATFORM_MAIL_ENABLED: 'true', PLATFORM_SCHEDULER_ENABLED: String(scheduler),
        PLATFORM_SCHEDULER_POLL_SECONDS: '1', PLATFORM_SCHEDULER_MAIL_SECONDS: '2',
        PLATFORM_STAFF_URL: 'https://control.scootsales.test' } : {}),
    }, stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true,
  });
  let logs = '';
  const logFile = path.join(E.OUTPUT_DIR, `staff-service-${port}.log`);
  fs.mkdirSync(E.OUTPUT_DIR, { recursive: true });
  fs.appendFileSync(logFile, `--- started pid ${child.pid} ---
`);
  const keepLog = (d) => { logs += d; fs.appendFileSync(logFile, d); };
  child.stdout.on('data', keepLog);
  child.stderr.on('data', keepLog);
  child.on('exit', (code, signal) => fs.appendFileSync(logFile, `--- exited code ${code} signal ${signal} ---
`));
  const stop = async () => {
    if (child.exitCode === null && child.pid) {
      if (process.platform === 'win32') spawnSync('taskkill', ['/PID', String(child.pid), '/T', '/F'], { windowsHide: true });
      else child.kill('SIGTERM');
    }
  };
  try {
    const deadline = Date.now() + 45000;
    for (;;) {
      try {
        if ((await fetch(`${url}/health`)).ok) break;
      } catch (_) {}
      if (child.exitCode !== null || Date.now() > deadline) throw new Error(`Staff API unavailable: ${logs.slice(-1500)}`);
      await new Promise((resolve) => setTimeout(resolve, 200));
    }
    const sessions = seedSessions(emails, roleEmails, uids);
    const headers = (who) => ({ ...sessions[emails[who]] });
    const deliverMail = () => JSON.parse(platform.python(['e2e/lib/mail_tick.py'], {
      env: { ...directory.mailEnv(), PYTHONUTF8: '1', PLATFORM_PROJECT_ID: directory.PLATFORM_PROJECT },
    }).trim().split(/\r?\n/).pop());
    return { url, headers, emails, stop, deliverMail };
  } catch (error) { await stop(); throw error; }
}

const CODE_SUBJECT = 'Your Scoot Sales sign-in code';
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function mailedCode(sink, email, seen) {
  const deadline = Date.now() + 30000;
  while (Date.now() < deadline) {
    const hits = (await sink.messages()).filter((m) => m.Subject === CODE_SUBJECT && !seen.has(m.ID)
      && m.To.some((to) => to.Address.toLowerCase() === email.toLowerCase()));
    if (hits.length) {
      seen.add(hits[0].ID);
      const message = await sink.message(hits[0].ID);
      const match = /sign-in code is (\d{6})/.exec(message.Text);
      if (!match) throw new Error(`no code in the mail: ${message.Text}`);
      return match[1];
    }
    await sleep(250);
  }
  throw new Error(`no sign-in code mail reached ${email}`);
}

async function signInControlCentre(page, email, sink, seen = new Set()) {
  await B.fillField(page, page.getByLabel('Email', { exact: true }), email);
  await B.fillField(page, page.getByLabel('Password', { exact: true }), E.PASSWORD);
  await page.getByRole('button', { name: 'Continue', exact: true }).click();
  await page.getByText(/^We sent a 6-digit code to /).first().waitFor({ timeout: 25000 });
  await B.fillField(page, page.getByLabel('Code', { exact: true }), await mailedCode(sink, email, seen));
  await page.getByRole('button', { name: 'Sign in', exact: true }).click();
  await page.getByRole('button', { name: /^Account menu/ }).first().waitFor({ timeout: 25000 });
}

const MIME = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.json': 'application/json; charset=utf-8',
  '.css': 'text/css; charset=utf-8', '.png': 'image/png', '.wasm': 'application/wasm', '.ico': 'image/x-icon',
  '.ttf': 'font/ttf', '.otf': 'font/otf', '.woff2': 'font/woff2',
};

async function serveBuild(buildDir) {
  const root = path.resolve(buildDir);
  if (!fs.existsSync(path.join(root, 'index.html'))) throw new Error(`build missing at ${root}`);
  const server = http.createServer((req, res) => {
    const url = decodeURIComponent(req.url.split('?')[0]);
    let file = path.join(root, url);
    if (!file.startsWith(root) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) file = path.join(root, 'index.html');
    res.writeHead(200, { 'Content-Type': MIME[path.extname(file)] || 'application/octet-stream', 'Cache-Control': 'no-store' });
    fs.createReadStream(file).pipe(res);
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  return {
    url: `http://127.0.0.1:${server.address().port}`,
    stop: () => new Promise((resolve) => server.close(resolve)),
  };
}

module.exports = { STAFF_PORT, STAFF_ROLE_EMAILS, startStaffApi, serveBuild, signInControlCentre };
