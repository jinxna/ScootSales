'use strict';

const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');
const B = require('../lib/browser.cjs');
const E = require('../lib/emulator.cjs');
const platform = require('../lib/platform.cjs');
const directory = require('../lib/platform_api.cjs');
const { startMailSink } = require('../lib/mail_sink.cjs');

const OUT = path.join(E.OUTPUT_DIR, 'cc_signin');
const OWNER = 'e2e.owner@example.test';
const OPERATOR = 'e2e.operator@example.test';
const PASSWORD = E.PASSWORD;
const STAFF_PORT = 18791;
const STAFF_URL = `http://127.0.0.1:${STAFF_PORT}`;
const CODE_SUBJECT = 'Your Scoot Sales sign-in code';
const RESET_SUBJECT = 'Reset your Scoot Sales password';
const ALERT_SUBJECT = 'New sign-in to your Scoot Sales account';
const STRANGER = 'e2e.stranger@example.test';
const NEW_PASSWORD = 'operator-new-pass-2026';
const GOOGLE_AUTH_HOSTS = /^https:\/\/(identitytoolkit|securetoken)\.googleapis\.com\//;
const NGINX_TEMPLATE = path.join(platform.ROOT, 'deploy', 'droplet', 'nginx-control.https.conf.tpl');
const EMULATOR_ORIGINS_ADDED_FOR_TEST = {
  'connect-src': [`http://${process.env.FIREBASE_AUTH_EMULATOR_HOST}`, `http://${process.env.FIRESTORE_EMULATOR_HOST}`, `ws://${process.env.FIRESTORE_EMULATOR_HOST}`],
  'frame-src': [`http://${process.env.FIREBASE_AUTH_EMULATOR_HOST}`],
};
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function enforcedPolicy() {
  const template = fs.readFileSync(NGINX_TEMPLATE, 'utf8');
  const match = template.match(/add_header Content-Security-Policy(?:-Report-Only)? "([^"]+)" always;/);
  if (!match) throw new Error('the Control Centre nginx template has no CSP header');
  return match[1].split(';').map((directive) => directive.trim()).filter(Boolean).map((directive) => {
    const [name, ...sources] = directive.split(/\s+/);
    return [name, ...sources, ...(EMULATOR_ORIGINS_ADDED_FOR_TEST[name] || [])].join(' ');
  }).join('; ');
}

function equal(actual, expected, label) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) throw new Error(`${label}: ${JSON.stringify(actual)} != ${JSON.stringify(expected)}`);
}

async function startStaffApi(key) {
  const child = spawn(platform.PYTHON, ['-m', 'uvicorn', 'platform_service.app:create_app', '--factory',
    '--host', '127.0.0.1', '--port', String(STAFF_PORT), '--log-level', 'warning', '--timeout-keep-alive', '120'], {
    cwd: platform.ROOT,
    windowsHide: true,
    env: {
      ...process.env, PYTHONUTF8: '1', PYTHONWARNINGS: 'ignore', PLATFORM_PROJECT_ID: directory.PLATFORM_PROJECT,
      PLATFORM_SCHEDULER_ENABLED: 'true', PLATFORM_SCHEDULER_POLL_SECONDS: '1', PLATFORM_SCHEDULER_MAIL_SECONDS: '2',
      PLATFORM_SIGNING_KEY_ID: key.keyId, PLATFORM_SIGNING_KEY: key.seed, PLATFORM_PUBLIC_KEYS: platform.publicKeysText(key),
      PLATFORM_STAFF_BOOTSTRAP_OWNERS: OWNER, PLATFORM_STAFF_DOMAINS: 'example.test',
      PLATFORM_STAFF_URL: 'https://control.scootsales.test',
      ...directory.mailEnv(),
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let logs = '';
  child.stdout.on('data', (d) => { logs += d; });
  child.stderr.on('data', (d) => { logs += d; });
  const stop = () => {
    if (child.exitCode !== null || !child.pid) return;
    if (process.platform === 'win32') spawnSync('taskkill', ['/PID', String(child.pid), '/T', '/F'], { windowsHide: true });
    else child.kill('SIGTERM');
  };
  const deadline = Date.now() + 45000;
  for (;;) {
    try {
      const response = await fetch(`${STAFF_URL}/staff/v1/invite/check`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ token: 'x' }),
      });
      if (response.status < 500) break;
    } catch {}
    if (child.exitCode !== null || Date.now() > deadline) {
      stop();
      throw new Error(`Staff API unavailable: ${logs.slice(-400)}`);
    }
    await sleep(200);
  }
  return { stop };
}

module.exports = {
  name: 'cc_signin',
  platformApi: false,
  async run(t) {
    const key = platform.ensureKey();
    const platformDb = E.client(directory.PLATFORM_PROJECT);
    await platformDb.reset();
    const evidence = { checks: [] };
    const note = (check, detail = {}) => evidence.checks.push({ check, ...detail });
    fs.mkdirSync(OUT, { recursive: true });
    const sink = await startMailSink();
    await sink.clear();
    const seenCodeMails = new Set();

    const owner = await platformDb.ensureUser(OWNER, 'E2E Owner');
    const verified = await fetch(`${platformDb.authBase}/accounts:update?key=fake-api-key`, {
      method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: 'Bearer owner' },
      body: JSON.stringify({ localId: owner.uid, emailVerified: true }),
    });
    if (!verified.ok) throw new Error(`could not verify the owner email: ${verified.status} ${await verified.text()}`);
    const probe = await fetch(`${platformDb.authBase}/accounts:signInWithPassword?key=fake-api-key`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ email: OWNER, password: PASSWORD, returnSecureToken: true }),
    });
    const audience = JSON.parse(Buffer.from((await probe.json()).idToken.split('.')[1], 'base64url').toString()).aud;
    if (audience !== directory.PLATFORM_PROJECT) {
      throw new Error(`The Auth emulator signs tokens for ${audience}. Run this flow with: npm run e2e:signin`);
    }
    const service = await startStaffApi(key);

    const policy = enforcedPolicy();
    const cspMessages = [];
    const documentHeaders = [];
    const watchCsp = (page) => page.on('console', (message) => {
      const text = message.text();
      if (!text.includes('Content Security Policy')) return;
      const googlePingBlocked = (/Connecting to 'https:\/\/apis\.google\.com\/js\/gen_204\?/.test(text) && /directive: "connect-src /.test(text))
        || /^Fetch API cannot load https:\/\/apis\.google\.com\/js\/gen_204\?\S*\. Refused to connect because it violates the document's Content Security Policy\.$/.test(text);
      if (googlePingBlocked) {
        note('blocked Google sign-in telemetry ping apis.google.com/js/gen_204 (expected: connect-src does not allow it)');
        return;
      }
      cspMessages.push(text.slice(0, 300));
    });
    const appUrl = new URL(t.urls.admin);
    const policyProxy = http.createServer((req, res) => {
      const upstream = http.request({ host: appUrl.hostname, port: appUrl.port, path: req.url, method: req.method, headers: req.headers }, (answer) => {
        const headers = { ...answer.headers };
        if (String(headers['content-type'] || '').includes('text/html')) {
          headers['content-security-policy'] = policy;
          documentHeaders.push(policy);
        }
        res.writeHead(answer.statusCode, headers);
        answer.pipe(res);
      });
      req.pipe(upstream);
    });
    await new Promise((resolve) => policyProxy.listen(0, '127.0.0.1', resolve));
    t.urls.admin = `http://127.0.0.1:${policyProxy.address().port}`;
    const step = (name, fn) => t.step(name, async () => {
      const result = await fn();
      if (cspMessages.length) throw new Error(`Content Security Policy violation: ${cspMessages[0]}`);
      return result;
    });
    const openSession = async (name) => {
      const s = await t.session('admin', { name });
      s.context.on('page', watchCsp);
      watchCsp(s.page);
      return s;
    };
    const open = async (name, beforeLoad) => {
      const s = await openSession(name);
      await s.context.route('**/staff/v1/**', async (route) => {
        const request = route.request();
        const url = new URL(request.url());
        const response = await route.fetch({ url: `${STAFF_URL}${url.pathname}${url.search}`,
          headers: { ...request.headers(), host: new URL(t.urls.admin).host } });
        return route.fulfill({ response });
      });
      if (beforeLoad) await beforeLoad(s.context);
      await B.openApp(s.page, t.urls.admin);
      return s;
    };
    const field = (s, label) => s.page.getByLabel(label, { exact: true });
    const button = (s, name) => s.page.getByRole('button', { name, exact: typeof name === 'string' });
    const accountMenu = (s) => s.page.getByRole('button', { name: /^Account menu/ }).first();
    const text = (s, value) => s.page.getByText(value, { exact: typeof value === 'string' }).first();
    const newTab = async (s) => {
      const page = await s.context.newPage();
      await B.openApp(page, t.urls.admin);
      return { ...s, page };
    };
    const fill = async (s, label, value) => B.fillField(s.page, field(s, label), value);

    const mailedCode = async (email) => {
      const deadline = Date.now() + 30000;
      while (Date.now() < deadline) {
        const hits = (await sink.messages()).filter((m) => m.Subject === CODE_SUBJECT && !seenCodeMails.has(m.ID)
          && m.To.some((to) => to.Address.toLowerCase() === email));
        if (hits.length) {
          seenCodeMails.add(hits[0].ID);
          const message = await sink.message(hits[0].ID);
          const match = /sign-in code is (\d{6})/.exec(message.Text);
          if (!match) throw new Error(`no code in the mail: ${message.Text}`);
          return match[1];
        }
        await sleep(250);
      }
      throw new Error(`no sign-in code mail reached ${email}`);
    };
    const allowNextCode = async (uid) => {
      const state = await platformDb.get('staff_login_codes', uid);
      if (state) await platformDb.put('staff_login_codes', uid, { ...state, requestedAt: '2000-01-01T00:00:00Z', windowCount: 0 });
    };
    const signInWithPassword = async (s, email, password) => {
      await fill(s, 'Email', email);
      await fill(s, 'Password', password);
      await button(s, 'Continue').click();
    };
    const finishWithCode = async (s, email) => {
      await text(s, new RegExp(`^(We sent a 6-digit code|The code is on its way) to ${email[0]}\\*\\*\\*@example\\.test\\.$`)).waitFor({ timeout: 25000 });
      const code = await mailedCode(email);
      await fill(s, 'Code', code);
      await button(s, 'Sign in').click();
      await accountMenu(s).waitFor({ timeout: 25000 });
    };
    const openAccount = async (s) => {
      await accountMenu(s).click();
      await s.page.getByRole('menuitem', { name: 'My account' }).click();
      await text(s, 'Where you are signed in').waitFor({ timeout: 25000 });
    };
    const googleSignIn = async (s, email, name) => {
      await s.context.route(/^https:\/\/apis\.google\.com\//, (route) => route.continue());
      const popupOpened = s.page.waitForEvent('popup', { timeout: 30000 });
      await button(s, 'Continue with Google').click();
      const popup = await popupOpened;
      await popup.waitForLoadState('domcontentloaded');
      const known = popup.locator('.js-reuse-account', { hasText: email });
      if (await known.count()) {
        await known.first().click();
      } else {
        await popup.locator('#add-account-button').click();
        await popup.locator('#email-input').fill(email);
        await popup.locator('#display-name-input').fill(name);
        await popup.locator('#sign-in').click();
      }
      await popup.waitForEvent('close', { timeout: 30000 }).catch(() => {});
    };
    const authAccounts = async (email) => {
      const response = await fetch(`${platformDb.authBase}/projects/${directory.PLATFORM_PROJECT}/accounts:lookup`, {
        method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: 'Bearer owner' },
        body: JSON.stringify({ email: [email] }),
      });
      if (!response.ok) throw new Error(`account lookup ${email}: ${response.status} ${await response.text()}`);
      return (await response.json()).users || [];
    };
    const sessionsOf = async (uid) => (await platformDb.list('staff_sessions')).filter((x) => x.uid === uid);
    const activeSessionsOf = async (uid) => (await sessionsOf(uid)).filter((x) => x.status === 'active');
    const savedFirebaseUsers = (s) => s.page.evaluate(() => new Promise((resolve) => {
      const prefix = 'firebase:authUser:';
      const inSession = Object.keys(sessionStorage).filter((k) => k.startsWith(prefix));
      const inLocal = Object.keys(localStorage).filter((k) => k.startsWith(prefix));
      const open = indexedDB.open('firebaseLocalStorageDb');
      open.onerror = () => resolve({ inSession, inLocal, inIndexedDb: [] });
      open.onsuccess = () => {
        const db = open.result;
        if (!db.objectStoreNames.contains('firebaseLocalStorage')) {
          db.close();
          resolve({ inSession, inLocal, inIndexedDb: [] });
          return;
        }
        const read = db.transaction('firebaseLocalStorage').objectStore('firebaseLocalStorage').getAllKeys();
        read.onsuccess = () => {
          db.close();
          resolve({ inSession, inLocal, inIndexedDb: read.result.filter((k) => String(k).startsWith(prefix)) });
        };
        read.onerror = () => { db.close(); resolve({ inSession, inLocal, inIndexedDb: [] }); };
      };
    }));
    const mailsTo = async (email, subject) => (await sink.messages())
      .filter((m) => m.Subject === subject && m.To.some((to) => to.Address.toLowerCase() === email));
    const waitForMails = async (email, subject, count) => {
      const deadline = Date.now() + 30000;
      while (Date.now() < deadline) {
        const hits = await mailsTo(email, subject);
        if (hits.length >= count) return hits;
        await sleep(250);
      }
      throw new Error(`expected ${count} "${subject}" mails to ${email}, found ${(await mailsTo(email, subject)).length}`);
    };
    let ownerPage;
    let backupCodes;

    try {
      await step('the enforced policy refuses an inline script on a new page', async () => {
        const probe = await open('policy-probe');
        const outcome = await probe.page.evaluate(() => {
          const script = document.createElement('script');
          script.text = 'window.inlineScriptRan = true';
          document.head.appendChild(script);
          return { inlineScriptRan: window.inlineScriptRan === true };
        });
        equal(outcome, { inlineScriptRan: false }, 'enforced policy probe');
        if (!documentHeaders.length || documentHeaders.some((value) => value !== policy)) throw new Error('the enforced policy header was not applied to the document');
        const refused = cspMessages.findIndex((message) => message.includes('inline script'));
        if (refused < 0) throw new Error('the probe produced no CSP console message, so the policy is not enforced');
        cspMessages.splice(refused, 1);
        note('enforced policy applied', { directives: policy.split(';').length });
        await probe.context.close();
      });
      await step('without Trusted Types the plain-path Firebase scripts still load under the policy', async () => {
        const consoleLines = [];
        const plain = await open('no-trusted-types', (context) => context.addInitScript(() => {
          Object.defineProperty(window, 'trustedTypes', { value: undefined, configurable: true });
        }));
        plain.page.on('console', (message) => consoleLines.push(message.text()));
        await field(plain, 'Email').waitFor({ timeout: 60000 });
        await plain.page.waitForTimeout(1500);
        if (consoleLines.some((line) => line.includes('TrustedTypes available'))) throw new Error('Trusted Types was still available, so the plain script path was not exercised');
        note('plain script path loaded under the policy');
        await plain.context.close();
      });
      await step('the sign-in page asks for email and password, and refuses a wrong password', async () => {
        ownerPage = await open('owner-a');
        await field(ownerPage, 'Email').waitFor({ timeout: 30000 });
        await signInWithPassword(ownerPage, OWNER, 'not the password');
        await text(ownerPage, 'The email or password is not right.').waitFor({ timeout: 15000 });
        await t.shot(ownerPage, 'wrong-password');
        note('wrong password refused');
      });

      await step('forgot password says the same for an address that is not staff and mails nothing', async () => {
        await fill(ownerPage, 'Email', 'nobody@example.test');
        await button(ownerPage, 'Forgot password?').click();
        await text(ownerPage, 'If that email is staff, a reset link is on its way.').waitFor({ timeout: 20000 });
        await sleep(2000);
        equal((await sink.messages()).filter((m) => m.Subject === RESET_SUBJECT).length, 0, 'reset mails for a stranger');
        await t.shot(ownerPage, 'forgot-password');
        note('forgot password reveals nothing about the address');
      });

      await step('show password toggles the password field', async () => {
        const hidden = ownerPage.page.locator('input[type="password"]');
        equal(await hidden.count(), 1, 'password inputs before');
        await button(ownerPage, 'Show password').first().click();
        await ownerPage.page.waitForFunction(() => document.querySelectorAll('input[type="password"]').length === 0, null, { timeout: 10000 });
      });

      await step('the right password asks for the emailed code; a wrong code shows tries left', async () => {
        await signInWithPassword(ownerPage, OWNER, PASSWORD);
        await text(ownerPage, new RegExp('^We sent a 6-digit code to e\\*\\*\\*@example\\.test\\.$')).waitFor({ timeout: 25000 });
        await t.shot(ownerPage, 'code-step');
        await fill(ownerPage, 'Code', '000000');
        await button(ownerPage, 'Sign in').click();
        await text(ownerPage, 'That code is not right. 4 tries left.').waitFor({ timeout: 15000 });
        await t.shot(ownerPage, 'wrong-code');
        note('wrong code shows tries left');
      });

      await step('the emailed code signs the bootstrap owner in', async () => {
        const code = await mailedCode(OWNER);
        await fill(ownerPage, 'Code', code);
        await button(ownerPage, 'Sign in').click();
        await accountMenu(ownerPage).waitFor({ timeout: 25000 });
        await ownerPage.page.getByText(OWNER, { exact: false }).first().waitFor({ timeout: 15000 });
        const stored = await ownerPage.page.evaluate(() => ({
          session: sessionStorage.getItem('staffSession'), localSession: localStorage.getItem('staffSession'),
          device: localStorage.getItem('staffDevice'),
        }));
        if (!stored.session || stored.localSession !== null || !stored.device) throw new Error(`storage: ${JSON.stringify(stored)}`);
        const saved = await savedFirebaseUsers(ownerPage);
        equal([saved.inSession.length, saved.inLocal.length, saved.inIndexedDb.length], [1, 0, 0], 'Firebase sign-in in session, local and IndexedDB storage');
        await t.shot(ownerPage, 'owner-signed-in');
        const otherTab = await newTab(ownerPage);
        await field(otherTab, 'Email').waitFor({ timeout: 30000 });
        equal(await accountMenu(otherTab).count(), 0, 'account menu in a new tab without Keep me signed in');
        await t.shot(otherTab, 'new-tab-not-remembered');
        await otherTab.page.close();
        note('owner signed in', { sessionInSessionStorageOnly: true, firebaseUserInSessionStorageOnly: true, newTabAsksSignIn: true });
        const [alert] = await waitForMails(OWNER, ALERT_SUBJECT, 1);
        const alertText = (await sink.message(alert.ID)).Text;
        if (!/signed in to from a new device: Chrome on \w+\./.test(alertText)) throw new Error(`sign-in alert: ${alertText}`);
        fs.writeFileSync(path.join(OUT, 'signin-alert-mail.txt'), alertText);
        note('new device sign-in alert mailed');
      });

      await step('the owner makes ten backup codes and sees them once', async () => {
        await openAccount(ownerPage);
        await text(ownerPage, 'Backup codes: 0 left').waitFor({ timeout: 15000 });
        await button(ownerPage, 'Make new codes').click();
        await text(ownerPage, 'Your new backup codes').waitFor({ timeout: 15000 });
        await button(ownerPage, 'Copy codes').waitFor();
        await button(ownerPage, 'Download codes').waitFor();
        const shown = await ownerPage.page.evaluate(() => Array.from(document.querySelectorAll('flt-semantics'))
          .map((n) => (n.getAttribute('aria-label') || n.textContent || '')).join('\n'));
        backupCodes = shown.match(/\b[a-z2-9]{4}-[a-z2-9]{4}-[a-z2-9]{4}\b/g) || [];
        backupCodes = [...new Set(backupCodes)];
        equal(backupCodes.length, 10, 'backup codes shown');
        fs.writeFileSync(path.join(OUT, 'backup-codes-count.txt'), `${backupCodes.length}\n`);
        await t.shot(ownerPage, 'backup-codes-dialog');
        await button(ownerPage, 'I saved them').click();
        await text(ownerPage, 'Backup codes: 10 left').waitFor({ timeout: 15000 });
        note('backup codes made', { count: backupCodes.length });
      });

      await step('adding a staff member outside the allowed domain shows the domain rule', async () => {
        await button(ownerPage, 'Staff and access').click();
        await button(ownerPage, 'Add staff member').click();
        await fill(ownerPage, 'Name', 'E2E Outsider');
        await fill(ownerPage, 'Work email', 'outsider@other.test');
        await t.shot(ownerPage, 'add-staff-dialog');
        if (await text(ownerPage, /\d+\/80/).count()) throw new Error('the name counter is drawn beside the email field');
        await button(ownerPage, 'Send invitation').click();
        await text(ownerPage, /allowed company domain/).first().waitFor({ timeout: 15000 });
        await t.shot(ownerPage, 'domain-error');
        await button(ownerPage, 'Cancel').click();
        note('domain error shown');
      });

      await step('Settings lists every approval the server asks for, and Add company is not under Onboarding', async () => {
        await button(ownerPage, 'Settings').click();
        for (const phrase of ['expiring a company', 'quoted prices', 'package overrides', 'package prices', 'payment voids']) {
          await text(ownerPage, new RegExp(phrase)).first().waitFor({ timeout: 15000 });
        }
        await t.shot(ownerPage, 'settings-approvals');
        await button(ownerPage, 'Companies').first().click();
        await button(ownerPage, 'Add company').click();
        await text(ownerPage, /Create draft/).first().waitFor({ timeout: 15000 });
        await t.shot(ownerPage, 'add-company-rail');
        await button(ownerPage, 'Staff and access').click();
      });

      await step('the owner invites an operator', async () => {
        await button(ownerPage, 'Add staff member').click();
        await fill(ownerPage, 'Name', 'E2E Operator');
        await fill(ownerPage, 'Work email', OPERATOR);
        await button(ownerPage, 'Send invitation').click();
        await text(ownerPage, /Invited, link ends/).first().waitFor({ timeout: 20000 });
        await t.shot(ownerPage, 'operator-invited');
      });

      let inviteHash;
      await step('the invitation mail carries a link that opens the accept page', async () => {
        const hits = await sink.waitForMessage(OPERATOR, { timeout: 60000 });
        const message = await sink.message(hits[0].ID);
        const match = /Open (\S+) to choose a password\./.exec(message.Text);
        if (!match || !match[1].startsWith('https://control.scootsales.test/#staffInvite=')) throw new Error(`invite mail: ${message.Text}`);
        inviteHash = match[1].slice(match[1].indexOf('#'));
        fs.writeFileSync(path.join(OUT, 'invitation-mail.txt'), message.Text.replace(/staffInvite=\S+/, 'staffInvite=<secret>'));
      });

      let operatorPage;
      await step('the operator accepts the invitation and signs in with password and code', async () => {
        operatorPage = await openSession('operator');
        await operatorPage.context.route('**/staff/v1/**', async (route) => {
          const request = route.request();
          const url = new URL(request.url());
          const response = await route.fetch({ url: `${STAFF_URL}${url.pathname}${url.search}`,
            headers: { ...request.headers(), host: new URL(t.urls.admin).host } });
          return route.fulfill({ response });
        });
        await B.openApp(operatorPage.page, `${t.urls.admin}/${inviteHash}`);
        await text(operatorPage, 'Accept your invitation').waitFor({ timeout: 30000 });
        await text(operatorPage, 'You are invited to the Control Centre as Operator.').waitFor();
        await text(operatorPage, OPERATOR).first().waitFor();
        await t.shot(operatorPage, 'accept-invitation');
        await fill(operatorPage, 'Choose a password', PASSWORD);
        await button(operatorPage, 'Create my account').click();
        await field(operatorPage, 'Email').waitFor({ timeout: 25000 });
        await signInWithPassword(operatorPage, OPERATOR, PASSWORD);
        await finishWithCode(operatorPage, OPERATOR);
        await t.shot(operatorPage, 'operator-signed-in');
        const staff = await platformDb.list('staff');
        const person = staff.find((x) => x.email === OPERATOR);
        equal([person.role, person.status], ['operator', 'active'], 'operator record');
        note('operator accepted and signed in');
      });

      await step('a used invitation link no longer works', async () => {
        const reuse = await openSession('reuse-invite');
        await reuse.context.route('**/staff/v1/**', async (route) => {
          const request = route.request();
          const url = new URL(request.url());
          const response = await route.fetch({ url: `${STAFF_URL}${url.pathname}${url.search}`,
            headers: { ...request.headers(), host: new URL(t.urls.admin).host } });
          return route.fulfill({ response });
        });
        await B.openApp(reuse.page, `${t.urls.admin}/${inviteHash}`);
        await text(reuse, /not valid|already used/).first().waitFor({ timeout: 30000 });
        await t.shot(reuse, 'used-invitation');
      });

      await step('the owner cancels an invitation sent to a mistyped email, and its link stops working', async () => {
        const MISTYPED = 'e2e.operatr@example.test';
        await button(ownerPage, 'Add staff member').click();
        await fill(ownerPage, 'Name', 'E2E Mistyped');
        await fill(ownerPage, 'Work email', MISTYPED);
        await button(ownerPage, 'Send invitation').click();
        const cancel = button(ownerPage, `Cancel invitation for ${MISTYPED}`);
        await cancel.waitFor({ timeout: 20000 });
        const hits = await sink.waitForMessage(MISTYPED, { timeout: 60000 });
        const message = await sink.message(hits[0].ID);
        const match = /Open (\S+) to choose a password\./.exec(message.Text);
        if (!match) throw new Error(`invite mail: ${message.Text}`);
        const mistypedHash = match[1].slice(match[1].indexOf('#'));
        await cancel.click();
        await text(ownerPage, 'Cancel invitation?').waitFor({ timeout: 10000 });
        await button(ownerPage, 'Cancel invitation').click();
        await text(ownerPage, 'The invitation was cancelled.').first().waitFor({ timeout: 20000 });
        await text(ownerPage, 'Turned off').first().waitFor({ timeout: 20000 });
        await t.shot(ownerPage, 'invitation-cancelled');
        const staff = await platformDb.list('staff');
        const person = staff.find((x) => x.email === MISTYPED);
        equal([person.status, person.inviteHash === undefined], ['disabled', true], 'cancelled invitation record');
        const stale = await openSession('cancelled-invite');
        await stale.context.route('**/staff/v1/**', async (route) => {
          const request = route.request();
          const url = new URL(request.url());
          const response = await route.fetch({ url: `${STAFF_URL}${url.pathname}${url.search}`,
            headers: { ...request.headers(), host: new URL(t.urls.admin).host } });
          return route.fulfill({ response });
        });
        await B.openApp(stale.page, `${t.urls.admin}/${mistypedHash}`);
        await text(stale, 'This invitation was cancelled. Ask the owner if you still need access.').waitFor({ timeout: 30000 });
        await t.shot(stale, 'cancelled-invitation-link');
        note('mistyped invitation cancelled; link refused with its own message');
      });

      await step('the owner removes a turned-off person; the row goes and the audit log records it', async () => {
        const MISTYPED = 'e2e.operatr@example.test';
        equal([await button(ownerPage, `Turn off access for ${OWNER}`).count(), await button(ownerPage, `Remove ${OPERATOR}`).count()], [0, 0], 'own row and active row offer neither Turn off nor Remove');
        await button(ownerPage, `Turn off access for ${OPERATOR}`).waitFor({ timeout: 10000 });
        const remove = button(ownerPage, `Remove ${MISTYPED}`);
        await remove.waitFor({ timeout: 10000 });
        await remove.click();
        await text(ownerPage, 'Remove E2E Mistyped?').waitFor({ timeout: 10000 });
        await text(ownerPage, new RegExp('This cannot be undone')).waitFor({ timeout: 10000 });
        await t.shot(ownerPage, 'remove-confirm');
        await button(ownerPage, 'Remove person').click();
        await text(ownerPage, `${MISTYPED} was removed.`).waitFor({ timeout: 20000 });
        await text(ownerPage, MISTYPED).waitFor({ state: 'detached', timeout: 20000 });
        await t.shot(ownerPage, 'person-removed');
        const staff = await platformDb.list('staff');
        equal([staff.some((x) => x.email === MISTYPED), staff.some((x) => x.email === OPERATOR)], [false, true], 'removed person gone, others kept');
        await button(ownerPage, 'Audit log').click();
        await text(ownerPage, /\(E2E Mistyped\) was removed\./).waitFor({ timeout: 20000 });
        await t.shot(ownerPage, 'removal-in-audit-log');
        const events = (await platformDb.list('audit_events')).filter((x) => x.action === 'staff.removed');
        equal(events.map((x) => x.actor), [OWNER], 'removal audit actor');
        await button(ownerPage, 'Staff and access').click();
        await button(ownerPage, `Turn off access for ${OPERATOR}`).waitFor({ timeout: 10000 });
        note('turned-off person removed; audit log shows it');
      });

      await step('the owner signs out, then signs in again with a backup code that works once', async () => {
        await openAccount(ownerPage);
        await button(ownerPage, 'Sign out').last().click();
        await field(ownerPage, 'Email').waitFor({ timeout: 25000 });
        await allowNextCode(owner.uid);
        await signInWithPassword(ownerPage, OWNER, PASSWORD);
        await text(ownerPage, /^We sent a 6-digit code to/).waitFor({ timeout: 25000 });
        await button(ownerPage, 'Use a backup code').click();
        await fill(ownerPage, 'Backup code', backupCodes[0]);
        await button(ownerPage, 'Sign in').click();
        await accountMenu(ownerPage).waitFor({ timeout: 25000 });
        await button(ownerPage, 'Dismiss').waitFor({ timeout: 15000 });
        await t.shot(ownerPage, 'backup-code-note');
        await button(ownerPage, 'Dismiss').click();
        await button(ownerPage, 'Dismiss').waitFor({ state: 'detached', timeout: 15000 });
        await openAccount(ownerPage);
        await text(ownerPage, 'Backup codes: 9 left').waitFor({ timeout: 15000 });
        await t.shot(ownerPage, 'signed-in-with-backup-code');
        note('backup code accepted', { left: 9 });

        await button(ownerPage, 'Sign out').last().click();
        await field(ownerPage, 'Email').waitFor({ timeout: 25000 });
        await allowNextCode(owner.uid);
        await signInWithPassword(ownerPage, OWNER, PASSWORD);
        await text(ownerPage, /^We sent a 6-digit code to/).waitFor({ timeout: 25000 });
        await button(ownerPage, 'Use a backup code').click();
        await fill(ownerPage, 'Backup code', backupCodes[0]);
        await button(ownerPage, 'Sign in').click();
        await text(ownerPage, /That code is not right\. \d tries left\./).waitFor({ timeout: 15000 });
        await t.shot(ownerPage, 'backup-code-used-twice');
        note('a used backup code is refused');
        await button(ownerPage, 'Use the emailed code').click();
        const code = await mailedCode(OWNER);
        await fill(ownerPage, 'Code', code);
        await button(ownerPage, 'Sign in').click();
        await accountMenu(ownerPage).waitFor({ timeout: 25000 });
      });

      let secondOwner;
      await step('a second device appears in the sessions list and can be signed out alone', async () => {
        secondOwner = await open('owner-b');
        await field(secondOwner, 'Email').waitFor({ timeout: 30000 });
        await allowNextCode(owner.uid);
        await signInWithPassword(secondOwner, OWNER, PASSWORD);
        await finishWithCode(secondOwner, OWNER);
        await openAccount(ownerPage);
        const rows = await sessionsOf(owner.uid);
        const active = rows.filter((x) => x.status === 'active');
        if (active.length < 2) throw new Error(`expected 2 active sessions, found ${active.length}`);
        await text(ownerPage, 'Current').first().waitFor({ timeout: 15000 });
        await t.shot(ownerPage, 'sessions-list');
        await ownerPage.page.getByRole('button', { name: 'Sign out', exact: true }).first().click();
        await text(ownerPage, 'That device was signed out.').waitFor({ timeout: 15000 });
        await button(secondOwner, 'Staff and access').click();
        await field(secondOwner, 'Email').waitFor({ timeout: 25000 });
        await t.shot(secondOwner, 'second-device-signed-out');
        note('single session ended');
        await waitForMails(OWNER, ALERT_SUBJECT, 2);
        await sleep(3000);
        equal((await mailsTo(OWNER, ALERT_SUBJECT)).length, 2, 'sign-in alerts: first device, then the second browser only');
        note('known device sign-ins send no alert', { alerts: 2 });
      });

      await step('Sign out of all devices ends every session of the owner', async () => {
        await openAccount(ownerPage);
        await button(ownerPage, 'Sign out of all devices').click();
        await button(ownerPage, 'Sign out of all devices').last().click();
        await field(ownerPage, 'Email').waitFor({ timeout: 25000 });
        await text(ownerPage, 'Your session ended. Sign in again.').waitFor({ timeout: 15000 });
        const remaining = (await sessionsOf(owner.uid)).filter((x) => x.status === 'active');
        equal(remaining.length, 0, 'active owner sessions after sign out of all devices');
        await t.shot(ownerPage, 'signed-out-everywhere');
        note('all sessions ended');
      });

      const KEEP_LABEL = 'Keep me signed in on this device for 30 days';
      const keepBox = (s, checked) => s.page.getByRole('checkbox', { name: KEEP_LABEL, checked });
      await step('a ticked Keep me signed in survives a reload', async () => {
        await allowNextCode(owner.uid);
        await signInWithPassword(ownerPage, OWNER, PASSWORD);
        await text(ownerPage, /^We sent a 6-digit code to/).waitFor({ timeout: 25000 });
        await keepBox(ownerPage, false).waitFor({ timeout: 15000 });
        await ownerPage.page.getByRole('checkbox', { name: KEEP_LABEL }).click();
        await keepBox(ownerPage, true).waitFor({ timeout: 15000 });
        await t.shot(ownerPage, 'keep-signed-in-ticked');
        await fill(ownerPage, 'Code', await mailedCode(OWNER));
        await button(ownerPage, 'Sign in').click();
        await accountMenu(ownerPage).waitFor({ timeout: 25000 });
        await ownerPage.page.reload({ waitUntil: 'domcontentloaded' });
        await B.enableSemantics(ownerPage.page);
        await accountMenu(ownerPage).waitFor({ timeout: 30000 });
        equal(await field(ownerPage, 'Email').count(), 0, 'password page shown after a reload of a remembered session');
        const otherTab = await newTab(ownerPage);
        await accountMenu(otherTab).waitFor({ timeout: 30000 });
        equal(await field(otherTab, 'Email').count(), 0, 'password page shown in a new tab of a remembered session');
        await t.shot(otherTab, 'new-tab-remembered');
        await otherTab.page.close();
        note('remembered session kept after a reload and in a new tab');
      });

      await step('a remembered device signs in with the password only and sends no code', async () => {
        await openAccount(ownerPage);
        await button(ownerPage, 'Sign out').last().click();
        await field(ownerPage, 'Email').waitFor({ timeout: 25000 });
        const before = (await mailsTo(OWNER, CODE_SUBJECT)).length;
        if (before < 1) throw new Error('the code mail count is not above zero before the remembered sign-in');
        await allowNextCode(owner.uid);
        await signInWithPassword(ownerPage, OWNER, PASSWORD);
        await accountMenu(ownerPage).waitFor({ timeout: 25000 });
        await sleep(3000);
        equal((await mailsTo(OWNER, CODE_SUBJECT)).length, before, 'code mails after a password-only sign-in');
        await t.shot(ownerPage, 'remembered-device-password-only');
        note('no code mailed for a remembered device', { codeMails: before });
      });

      await step('Sign out of all devices makes the next sign-in ask for the code again', async () => {
        await openAccount(ownerPage);
        await button(ownerPage, 'Sign out of all devices').click();
        await button(ownerPage, 'Sign out of all devices').last().click();
        await field(ownerPage, 'Email').waitFor({ timeout: 25000 });
        const before = (await mailsTo(OWNER, CODE_SUBJECT)).length;
        await allowNextCode(owner.uid);
        await signInWithPassword(ownerPage, OWNER, PASSWORD);
        await text(ownerPage, /^We sent a 6-digit code to/).waitFor({ timeout: 25000 });
        await keepBox(ownerPage, false).waitFor({ timeout: 15000 });
        await waitForMails(OWNER, CODE_SUBJECT, before + 1);
        await t.shot(ownerPage, 'code-asked-again-after-sign-out-all');
        await button(ownerPage, 'Back').click();
        await field(ownerPage, 'Email').waitFor({ timeout: 25000 });
        await field(ownerPage, 'Password').click();
        await ownerPage.page.waitForFunction(() => document.querySelectorAll('input[type="password"]').length === 1, null, { timeout: 10000 });
        const leftover = await ownerPage.page.evaluate(() => [...document.querySelectorAll('input[type="password"]')].filter((input) => input.value.length > 0).length);
        equal(leftover, 0, 'password inputs still holding the typed password after a good sign-in');
        note('code asked again after Sign out of all devices');
      });

      await step('forgot password mails a signed-in-before staff member a server-made reset link', async () => {
        await fill(ownerPage, 'Email', OWNER);
        await button(ownerPage, 'Forgot password?').click();
        await text(ownerPage, 'If that email is staff, a reset link is on its way.').waitFor({ timeout: 20000 });
        const [hit] = await waitForMails(OWNER, RESET_SUBJECT, 1);
        const message = await sink.message(hit.ID);
        const link = /Open (\S+) to set a new password\./.exec(message.Text);
        if (!link) throw new Error(`reset mail: ${message.Text}`);
        const url = new URL(link[1]);
        equal([url.searchParams.get('mode'), Boolean(url.searchParams.get('oobCode'))], ['resetPassword', true], 'reset link action');
        equal(message.Stub.template, 'password_reset', 'reset template');
        equal((await sink.messages()).filter((m) => m.Subject === RESET_SUBJECT).length, 1, 'reset mails in total');
        const jobs = (await platformDb.list('mail_jobs')).filter((job) => job.kind === 'password_reset');
        equal(jobs.map((job) => [job.status, job.payload.resetUrl]), [['sent', 'removed']], 'stored reset job');
        fs.writeFileSync(path.join(OUT, 'reset-mail.txt'), message.Text.replace(/oobCode=[^&\s]+/, 'oobCode=<secret>'));
        note('reset link mailed by the platform', { mode: url.searchParams.get('mode'), host: url.host });
      });

      const operatorUid = (await platformDb.list('staff')).find((x) => x.email === OPERATOR).uid;
      await step('a reload keeps the operator signed in and never calls Google servers', async () => {
        const leaks = [];
        await operatorPage.page.route(GOOGLE_AUTH_HOSTS, (route) => {
          leaks.push(route.request().url());
          return route.fulfill({ status: 404, body: '' });
        });
        await operatorPage.page.reload({ waitUntil: 'domcontentloaded' });
        await B.enableSemantics(operatorPage.page);
        await accountMenu(operatorPage).waitFor({ timeout: 30000 });
        await openAccount(operatorPage);
        await button(operatorPage, 'Sign out').last().click();
        await field(operatorPage, 'Email').waitFor({ timeout: 25000 });
        await allowNextCode(operatorUid);
        await signInWithPassword(operatorPage, OPERATOR, PASSWORD);
        await finishWithCode(operatorPage, OPERATOR);
        equal(leaks, [], 'requests to Google sign-in servers');
        await t.shot(operatorPage, 'reload-without-google');
        note('saved sign-in restored on the emulator only', { googleRequests: 0 });
      });

      await step('Continue with Google for an email that is not staff is refused and leaves no account', async () => {
        const stranger = await open('google-stranger');
        await field(stranger, 'Email').waitFor({ timeout: 30000 });
        await googleSignIn(stranger, STRANGER, 'E2E Stranger');
        await text(stranger, /^This Google account is not a Control Centre account\./).waitFor({ timeout: 25000 });
        await field(stranger, 'Email').waitFor();
        equal(await authAccounts(STRANGER), [], 'Auth accounts for the refused Google email');
        await t.shot(stranger, 'google-stranger-refused');
        note('Google sign-in for a stranger refused and the new account removed');
      });

      let operatorGoogle;
      await step('the operator continues with Google, keeps one account, and still enters the emailed code', async () => {
        operatorGoogle = await open('operator-google');
        await field(operatorGoogle, 'Email').waitFor({ timeout: 30000 });
        await allowNextCode(operatorUid);
        await googleSignIn(operatorGoogle, OPERATOR, 'E2E Operator');
        await finishWithCode(operatorGoogle, OPERATOR);
        const [account] = await authAccounts(OPERATOR);
        equal([account.localId, account.providerUserInfo.map((p) => p.providerId).sort()],
          [operatorUid, ['google.com', 'password']], 'operator account after Google');
        await t.shot(operatorGoogle, 'operator-google-signed-in');
        note('Google linked to the invited account', { sameUid: true });
      });

      await step('the operator changes the password; every other session ends and the old password stops working', async () => {
        equal((await activeSessionsOf(operatorUid)).length, 2, 'active operator sessions before the change');
        await openAccount(operatorGoogle);
        await text(operatorGoogle, `The new password must have 12 to 128 characters.`).waitFor({ timeout: 15000 });
        await fill(operatorGoogle, 'Current password', 'not the password');
        await fill(operatorGoogle, 'New password', NEW_PASSWORD);
        await fill(operatorGoogle, 'Confirm new password', NEW_PASSWORD);
        await button(operatorGoogle, 'Change password').click();
        await text(operatorGoogle, 'Your current password is not right.').waitFor({ timeout: 15000 });
        await fill(operatorGoogle, 'Current password', PASSWORD);
        await fill(operatorGoogle, 'New password', 'short');
        await fill(operatorGoogle, 'Confirm new password', 'short');
        await button(operatorGoogle, 'Change password').click();
        await text(operatorGoogle, 'Use a new password of 12 to 128 characters.').waitFor({ timeout: 15000 });
        equal((await activeSessionsOf(operatorUid)).length, 2, 'active operator sessions after refused changes');
        await fill(operatorGoogle, 'New password', NEW_PASSWORD);
        await fill(operatorGoogle, 'Confirm new password', NEW_PASSWORD);
        await button(operatorGoogle, 'Change password').click();
        await field(operatorGoogle, 'Email').waitFor({ timeout: 25000 });
        await text(operatorGoogle, 'Your password is changed. Sign in with the new password.').waitFor({ timeout: 20000 });
        equal((await activeSessionsOf(operatorUid)).length, 0, 'active operator sessions after the password change');
        await t.shot(operatorGoogle, 'password-changed');
        await signInWithPassword(operatorGoogle, OPERATOR, PASSWORD);
        await text(operatorGoogle, 'The email or password is not right.').waitFor({ timeout: 15000 });
        await allowNextCode(operatorUid);
        await signInWithPassword(operatorGoogle, OPERATOR, NEW_PASSWORD);
        await finishWithCode(operatorGoogle, OPERATOR);
        note('password changed', { oldPasswordRefused: true, newPasswordWorks: true, sessionsEnded: 2 });
      });

      await step('an idle Control Centre signs the staff member out and ends the server session', async () => {
        equal((await activeSessionsOf(operatorUid)).length, 1, 'active operator sessions before the idle reload');
        await operatorGoogle.page.evaluate(() => localStorage.setItem('scoot.admin.lastActivityMs', String(Date.now() - 2 * 60 * 60 * 1000)));
        await operatorGoogle.page.reload({ waitUntil: 'domcontentloaded' });
        await B.enableSemantics(operatorGoogle.page);
        await field(operatorGoogle, 'Email').waitFor({ timeout: 30000 });
        await text(operatorGoogle, 'Session expired. Sign in again.').waitFor({ timeout: 15000 });
        equal((await activeSessionsOf(operatorUid)).length, 0, 'active operator sessions after the idle sign-out');
        await text(operatorGoogle, /signed out after \d+ minutes/).waitFor({ timeout: 15000 });
        await t.shot(operatorGoogle, 'idle-signed-out');
        await allowNextCode(operatorUid);
        await signInWithPassword(operatorGoogle, OPERATOR, NEW_PASSWORD);
        await finishWithCode(operatorGoogle, OPERATOR);
        note('idle sign-out ends the session', { sessionsAfter: 0 });
      });

      await step('a Google-only staff member is told Google manages the password and can ask for a set-password link', async () => {
        const unlinked = await fetch(`${platformDb.authBase}/projects/${directory.PLATFORM_PROJECT}/accounts:update`, {
          method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: 'Bearer owner' },
          body: JSON.stringify({ localId: operatorUid, deleteAttribute: ['PASSWORD'] }),
        });
        if (!unlinked.ok) throw new Error(`could not remove the password: ${unlinked.status} ${await unlinked.text()}`);
        await openAccount(operatorGoogle);
        await button(operatorGoogle, 'Sign out').last().click();
        await field(operatorGoogle, 'Email').waitFor({ timeout: 25000 });
        await allowNextCode(operatorUid);
        await googleSignIn(operatorGoogle, OPERATOR, 'E2E Operator');
        await finishWithCode(operatorGoogle, OPERATOR);
        await openAccount(operatorGoogle);
        await text(operatorGoogle, /^You sign in with Google\. Google manages that password\./).waitFor({ timeout: 15000 });
        await button(operatorGoogle, 'Set a password').click();
        await text(operatorGoogle, `We sent a link to ${OPERATOR}. Open it to set a password.`).waitFor({ timeout: 20000 });
        const [hit] = await waitForMails(OPERATOR, RESET_SUBJECT, 1);
        const link = /Open (\S+) to set a new password\./.exec((await sink.message(hit.ID)).Text);
        if (!link) throw new Error('no set-password link in the mail');
        await t.shot(operatorGoogle, 'google-only-set-password');
        note('Google-only staff get a set-password link');
      });
      await step('no page reported a Content Security Policy violation', async () => {});
    } finally {
      service.stop();
      policyProxy.close();
      await sink.close();
      fs.writeFileSync(path.join(OUT, 'result.json'), `${JSON.stringify(evidence, null, 2)}\n`);
    }
  },
};
