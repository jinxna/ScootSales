'use strict';

const fs = require('node:fs');
const path = require('node:path');
const B = require('../lib/browser.cjs');
const E = require('../lib/emulator.cjs');
const admin = require('../lib/admin.cjs');
const mobile = require('../lib/mobile.cjs');
const directory = require('../lib/platform_api.cjs');
const platform = require('../lib/platform.cjs');
const { startMailSink } = require('../lib/mail_sink.cjs');

const OUT = path.join(E.OUTPUT_DIR, 'v5_mail_delivery');
const PASSWORD = E.PASSWORD;
const BRANCH_NAME = 'E2E Kuching Branch';
const MAILED = { name: 'E2E Mailed Salesman', code: 'S811', email: 'e2e.mailed.salesman@example.test' };
const SUPERVISOR = { name: 'E2E Mailed Supervisor', code: 'SUP-811', email: 'e2e.mailed.supervisor@example.test', role: 'Supervisor' };
const RETRIED = { name: 'E2E Retried Salesman', code: 'S812', email: 'e2e.retried.salesman@example.test' };
const STAFF_OPERATOR = 'e2e.mail.operator@example.test';
const RESET_SUBJECT = 'Reset your Scoot Sales password';

function expectEqual(actual, expected, what) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`${what}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}

function header(headers, name) {
  const key = Object.keys(headers).find((candidate) => candidate.toLowerCase() === name.toLowerCase());
  return key ? headers[key] : [];
}

function inviteLink(text) {
  const match = /Open (\S+)\. This invitation expires at/.exec(text);
  if (!match) throw new Error(`the mail text has no invitation link: ${text}`);
  return match[1];
}

function localInviteUrl(adminUrl, link) {
  const hash = link.slice(link.indexOf('#'));
  const base = new URL(adminUrl);
  return `${base.origin}${base.pathname.replace(/\/$/, '')}/${hash}`;
}

async function api(method, url, body, headers = {}) {
  const response = await fetch(url, {
    method, headers: { 'Content-Type': 'application/json', ...headers }, body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await response.text();
  return { status: response.status, body: text ? JSON.parse(text) : null };
}

function staffHeaders() {
  const { firestoreHost } = E.requireEmulators();
  const out = platform.python(['e2e/lib/staff_session.py'], {
    input: JSON.stringify({ project: directory.PLATFORM_PROJECT, roles: { [STAFF_OPERATOR]: 'operator' } }),
    env: { ...process.env, PYTHONWARNINGS: 'ignore', FIRESTORE_EMULATOR_HOST: firestoreHost,
      PLATFORM_PROJECT_ID: directory.PLATFORM_PROJECT },
  });
  return JSON.parse(out.trim().split(/\r?\n/).pop())[STAFF_OPERATOR];
}

function formatCode(code) {
  return [code.slice(0, 4), code.slice(4, 8), code.slice(8)].join('-');
}

module.exports = {
  name: 'v5_mail_delivery',
  platformMail: true,
  async run(t) {
    const { db, accounts } = t;
    const platformDb = E.client(directory.PLATFORM_PROJECT);
    const company = platform.harnessRecord();
    const evidence = { project: E.PROJECT, platformProject: directory.PLATFORM_PROJECT, checks: [] };
    const note = (check, detail = {}) => evidence.checks.push({ check, ...detail });
    fs.mkdirSync(OUT, { recursive: true });
    const sink = await startMailSink();
    const jobFor = (email) => platformDb.waitForQuery('mail_jobs', (job) => job.recipient === email, { label: `mail job for ${email}` });
    const waitJob = (email, predicate, label, timeout = 60000) => platformDb.waitForQuery(
      'mail_jobs', (job) => job.recipient === email && predicate(job), { label, timeout },
    );
    const saveMail = (prefix, message) => {
      fs.writeFileSync(path.join(OUT, `${prefix}.txt`), message.Text);
      fs.writeFileSync(path.join(OUT, `${prefix}.html`), message.HTML);
      fs.writeFileSync(path.join(OUT, `${prefix}.json`), `${JSON.stringify({
        ID: message.ID, From: message.From, To: message.To, Subject: message.Subject, Headers: message.Headers,
      }, null, 2)}\n`);
    };
    let adminS;
    let mailedCode;

    try {
      await t.step('the mail sink starts empty', async () => {
        await sink.clear();
        expectEqual((await sink.messages()).length, 0, 'messages in the sink');
        note('sink', { external: sink.external });
      });

      await t.step('admin invites a salesman by email', async () => {
        adminS = await t.session('admin', admin.grantClipboard);
        await B.loginAdmin(adminS.page, adminS.url, accounts.admin.email);
        await admin.waitForShell(adminS.page);
        const created = await admin.createUser(adminS.page, {
          name: MAILED.name, code: MAILED.code, email: MAILED.email, branchName: BRANCH_NAME,
        });
        mailedCode = created.code;
        await t.shot(adminS, 'invited-by-email');
      });

      let message;
      await t.step('the scheduler delivers one invitation mail to the sink without any CLI call', async () => {
        const hits = await sink.waitForMessage(MAILED.email);
        expectEqual(hits.length, 1, 'mails to the invited address');
        message = await sink.message(hits[0].ID);
        saveMail('invitation-mail', message);
        const job = await waitJob(MAILED.email, (j) => j.status === 'sent', 'mail job sent');
        expectEqual(job.attempts, 1, 'delivery attempts');
        expectEqual(job.kind, 'invitation', 'mail job kind');
        expectEqual(header(message.Headers, 'X-Mail-Job'), [job.jobId], 'X-Mail-Job header');
        expectEqual(job.providerMessageId, `${job.jobId}@scoot.localhost`, 'provider message id');
        const lease = await platformDb.waitForDoc('scheduler_leases', 'mail', (l) => l.lastStatus === 'ran', { label: 'mail lease run by the scheduler' });
        expectEqual(lease.project, directory.PLATFORM_PROJECT, 'mail lease project');
        if (!lease.lastRunOwner) throw new Error('the mail lease has no owner');
        const invitation = (await platformDb.list('invitations')).find((i) => i.displayName === MAILED.name);
        expectEqual([invitation.mail.status, invitation.mail.jobId], ['queued', job.jobId], 'invitation mail outcome');
        note('delivered', { jobId: job.jobId, attempts: job.attempts, lease: lease.lastStatus });
      });

      let payload;
      await t.step('the mail has the approved subject, sender, recipient and an invitation link', async () => {
        expectEqual(message.Subject, `Your invitation to ${company.legalName}`, 'subject');
        expectEqual(message.From.Address, directory.MAIL_SENDER, 'sender address');
        expectEqual(message.To.map((to) => to.Address), [MAILED.email], 'recipients');
        const link = inviteLink(message.Text);
        if (!link.startsWith(`${directory.MAIL_INVITE_URL}#invite=`)) throw new Error(`invitation link: ${link}`);
        payload = link.slice(`${directory.MAIL_INVITE_URL}#invite=`.length);
        const parts = payload.split(':');
        expectEqual(parts.slice(0, 3), ['scoot-invite', '1', company.workspace], 'invitation payload prefix');
        expectEqual(formatCode(parts[3]), mailedCode, 'code in the mail and in the dashboard dialog');
        if (!message.HTML.includes(`href="${link}"`)) throw new Error('the HTML part does not link to the same address');
        if (!/<a [^>]*>Accept invitation<\/a>/.test(message.HTML)) throw new Error('the HTML part has no accept link');
        note('mail content', { subject: message.Subject, from: message.From.Address, linkPrefix: directory.MAIL_INVITE_URL });
      });

      await t.step('the invited person redeems with the code from the mail on the phone and signs in again', async () => {
        const phone = await t.session('mobile', { viewport: mobile.MOBILE_VIEWPORT, name: 'phone-mailed' });
        await mobile.redeemInvitation(phone.page, phone.url, { code: formatCode(payload.split(':')[3]), check: MAILED.email, password: PASSWORD });
        await B.submitEmailCode(phone.page, await sink.waitForEmailCode(MAILED.email));
        await B.see(phone.page, 'Invitation accepted', { timeout: 30000 });
        const signInId = await mobile.finishRedeem(phone.page);
        if (signInId !== null) expectEqual(signInId, MAILED.email, 'sign-in id');
        const record = await platformDb.waitForQuery('invitations', (i) => i.displayName === MAILED.name && i.status === 'redeemed', { label: 'redeemed' });
        const access = await db.waitForDoc('user_access', record.uid, (a) => a.status === 'active');
        expectEqual(access.isActive, true, 'access isActive after redeem');
        await mobile.signOut(phone.page);
        await B.loginMobile(phone.page, phone.url, MAILED.email);
        await mobile.waitForHome(phone.page);
        await t.shot(phone, 'signed-in-after-mail');
        note('redeemed from mail', { status: record.status });
      });

      let supervisorLink;
      let supervisorCode;
      await t.step('admin invites a supervisor by email and the mail arrives in the sink', async () => {
        const created = await admin.createUser(adminS.page, {
          name: SUPERVISOR.name, code: SUPERVISOR.code, email: SUPERVISOR.email, role: SUPERVISOR.role, branchName: BRANCH_NAME,
        });
        supervisorCode = created.code;
        const hits = await sink.waitForMessage(SUPERVISOR.email);
        expectEqual(hits.length, 1, 'mails to the invited supervisor');
        const mail = await sink.message(hits[0].ID);
        saveMail('supervisor-invitation-mail', mail);
        const link = inviteLink(mail.Text);
        if (!link.startsWith(`${directory.MAIL_INVITE_URL}#invite=`)) throw new Error(`invitation link: ${link}`);
        supervisorLink = localInviteUrl(adminS.url, link);
        expectEqual(formatCode(link.split(':').pop()), supervisorCode, 'code in the mail and in the dashboard dialog');
        note('supervisor mail', { linkHost: directory.MAIL_INVITE_URL, localLinkShape: supervisorLink.replace(/#invite=.*/, '#invite=<payload>') });
      });

      await t.step('a link that is not valid shows the not-valid notice, an empty code field and no fragment in the address bar', async () => {
        const bad = await t.session('admin', { name: 'admin-invite-garbage' });
        await B.openApp(bad.page, localInviteUrl(bad.url, '#invite=garbage'));
        await B.see(bad.page, 'This invitation link is not valid. Enter the code from your invitation email below.', { timeout: 60000 });
        await B.see(bad.page, 'Redeem your invitation');
        expectEqual(await B.semantic(bad.page, 'Invitation link opened. Your code is filled in below.').count(), 0, 'success notice on a bad link');
        expectEqual(await B.focusedValue(bad.page.locator('input').nth(0)), '', 'Invitation code field on a bad link');
        expectEqual(new URL(bad.page.url()).hash, '', 'URL fragment after load');
        if (bad.page.url().includes('invite=')) throw new Error(`the address bar still has the link: ${bad.page.url()}`);
        await t.shot(bad, 'invite-link-not-valid');
        note('garbage link', { url: bad.page.url() });
      });

      await t.step('the mailed link opens the dashboard with the code filled in and the supervisor redeems it', async () => {
        const fresh = await t.session('admin', { name: 'admin-invite-link' });
        await B.openApp(fresh.page, supervisorLink);
        await B.see(fresh.page, 'Invitation link opened. Your code is filled in below.', { timeout: 60000 });
        await B.see(fresh.page, 'Redeem your invitation');
        const inputs = fresh.page.locator('input');
        expectEqual(await B.focusedValue(inputs.nth(0)), supervisorCode, 'prefilled Invitation code');
        expectEqual(new URL(fresh.page.url()).hash, '', 'URL fragment after load');
        if (fresh.page.url().includes('invite=')) throw new Error(`the address bar still has the link: ${fresh.page.url()}`);
        await t.shot(fresh, 'invite-link-prefilled');
        await B.fillField(fresh.page, inputs.nth(1), SUPERVISOR.email);
        await B.fillField(fresh.page, inputs.nth(2), PASSWORD);
        await B.fillField(fresh.page, inputs.nth(3), PASSWORD);
        await fresh.page.getByRole('button', { name: 'Set password and sign in', exact: true }).click();
        await B.submitEmailCode(fresh.page, await sink.waitForEmailCode(SUPERVISOR.email));
        await admin.waitForSupervisorShell(fresh.page);
        await t.shot(fresh, 'invite-link-supervisor-shell');
        const record = await platformDb.waitForQuery('invitations', (i) => i.displayName === SUPERVISOR.name && i.status === 'redeemed', { label: 'supervisor redeemed from the mailed link' });
        const access = await db.waitForDoc('user_access', record.uid, (a) => a.status === 'active');
        expectEqual([access.role, access.isActive], ['supervisor', true], 'supervisor access after redeem');
        note('redeemed from mailed link', { role: access.role, status: access.status });
      });

      let bounced;
      await t.step('a hard bounce from the Brevo webhook marks the mail job and blocks the address', async () => {
        bounced = await waitJob(SUPERVISOR.email, (j) => j.status === 'sent' && j.kind === 'invitation', 'supervisor invitation sent');
        const event = { event: 'hard_bounce', email: SUPERVISOR.email, 'message-id': `<${bounced.providerMessageId}>`,
          ts_event: Math.floor(Date.now() / 1000), reason: 'mailbox does not exist', 'X-Mailin-custom': bounced.jobId };
        const url = `${platform.PLATFORM_API_URL}/v1/mail/brevo-events`;
        expectEqual((await api('POST', url, event, { Authorization: 'Bearer wrong-secret-wrong-secret' })).status, 401, 'wrong webhook secret');
        const auth = { Authorization: `Bearer ${directory.MAIL_WEBHOOK_SECRET}` };
        expectEqual((await api('POST', url, event, auth)).body, { accepted: 1, duplicate: 0, ignored: 0 }, 'first event');
        expectEqual((await api('POST', url, [event], auth)).body, { accepted: 0, duplicate: 1, ignored: 0 }, 'repeated event');
        const job = await waitJob(SUPERVISOR.email, (j) => j.jobId === bounced.jobId && j.deliveryStatus === 'hard_bounce', 'job shows the bounce');
        const blocks = (await platformDb.list('mail_suppressions')).filter((row) => row.status === 'active');
        expectEqual(blocks.map((row) => [row.reason, row.jobId, row.recipientHint]), [['hard_bounce', bounced.jobId, 'e***@example.test']], 'active blocks');
        fs.writeFileSync(path.join(OUT, 'bounce-event.json'), `${JSON.stringify({ event, job: { jobId: job.jobId, deliveryStatus: job.deliveryStatus, deliveryEvents: job.deliveryEvents } }, null, 2)}
`);
        note('bounce recorded', { jobId: job.jobId, deliveryStatus: job.deliveryStatus });
      });

      await t.step('the next mail to the blocked address is held, staff lift the block, and mail flows again', async () => {
        const reset = `${platform.PLATFORM_API_URL}/v1/w/${company.workspace}/auth/password-reset`;
        expectEqual((await api('POST', reset, { email: SUPERVISOR.email, client: 'dashboard' })).body, { status: 'accepted' }, 'reset answer');
        const held = await waitJob(SUPERVISOR.email, (j) => j.kind === 'password_reset' && j.status === 'held', 'reset mail held');
        expectEqual([held.heldReason, held.payload.resetUrl], ['recipient_suppressed', 'removed'], 'held reset job');
        const staff = staffHeaders();
        const heldRows = (await api('GET', `${platform.PLATFORM_API_URL}/staff/v1/mail/held`, undefined, staff)).body.jobs;
        expectEqual(heldRows.filter((row) => row.jobId === held.jobId).map((row) => row.reason), ['recipient_suppressed'], 'held list');
        const listed = await api('GET', `${platform.PLATFORM_API_URL}/staff/v1/mail/suppressions`, undefined, staff);
        expectEqual(listed.status, 200, 'suppression list status');
        const block = listed.body.suppressions.find((row) => row.reason === 'hard_bounce');
        expectEqual([block.recipient, block.kind, block.companyName], ['e***@example.test', 'invitation', company.legalName], 'suppression row');
        const retry = await api('POST', `${platform.PLATFORM_API_URL}/staff/v1/mail/held/${held.jobId}/retry`, undefined, staff);
        expectEqual(retry.status, 409, 'a held one-time reset link is not sent again');
        const lifted = await api('POST', `${platform.PLATFORM_API_URL}/staff/v1/mail/suppressions/${block.suppressionId}/lift`,
          { reason: 'The supervisor fixed the mailbox' }, staff);
        expectEqual([lifted.status, lifted.body.suppression.status, lifted.body.suppression.liftedBy], [200, 'lifted', STAFF_OPERATOR], 'lift');
        const audit = (await platformDb.list('audit_events')).filter((row) => row.action === 'mail.suppression_lifted');
        expectEqual(audit.map((row) => row.actor), [STAFF_OPERATOR], 'lift audit event');
        expectEqual((await api('POST', reset, { email: SUPERVISOR.email })).body, { status: 'accepted' }, 'second reset answer');
        await waitJob(SUPERVISOR.email, (j) => j.kind === 'password_reset' && j.status === 'sent', 'reset mail sent after the lift');
        const hits = (await sink.messages()).filter((m) => m.Subject === RESET_SUBJECT && m.To.some((to) => to.Address === SUPERVISOR.email));
        expectEqual(hits.length, 1, 'reset mails delivered');
        const mail = await sink.message(hits[0].ID);
        const link = /Open (\S+) to set a new password\./.exec(mail.Text);
        expectEqual(link && new URL(link[1]).searchParams.get('mode'), 'resetPassword', 'reset link action');
        fs.writeFileSync(path.join(OUT, 'reset-after-lift.txt'), mail.Text.replace(/oobCode=[^&\s]+/, 'oobCode=<secret>'));
        note('block lifted and mail delivered', { heldJob: held.jobId, retryStatus: retry.status });
      });

      if (sink.external) {
        note('retry', { skipped: 'a Mailpit that was already running cannot be stopped by the harness' });
      } else {
        let first;
        await t.step('with the sink stopped the mail job is retried, not lost', async () => {
          await sink.stop();
          await admin.createUser(adminS.page, {
            name: RETRIED.name, code: RETRIED.code, email: RETRIED.email, branchName: BRANCH_NAME,
          });
          first = await jobFor(RETRIED.email);
          const retried = await waitJob(RETRIED.email, (j) => j.status === 'queued' && j.attempts >= 1 && Boolean(j.lastFailure),
            'mail job queued for retry');
          if (!(retried.nextAttemptAt > retried.updatedAt)) throw new Error(`no later retry time: ${retried.nextAttemptAt} / ${retried.updatedAt}`);
          if (!/not reachable/.test(retried.lastFailure)) throw new Error(`failure text: ${retried.lastFailure}`);
          note('retry scheduled', { jobId: first.jobId, attempts: retried.attempts, nextAttemptAt: retried.nextAttemptAt, lastFailure: retried.lastFailure });
        });
        await t.step('after the sink returns the retried mail is delivered once', async () => {
          await sink.restart();
          const hits = await sink.waitForMessage(RETRIED.email);
          const sent = await waitJob(RETRIED.email, (j) => j.status === 'sent', 'retried mail job sent');
          expectEqual(sent.jobId, first.jobId, 'the same job was delivered');
          if (sent.attempts < 2) throw new Error(`attempts: ${sent.attempts}`);
          await new Promise((resolve) => setTimeout(resolve, 6000));
          const all = (await sink.messages()).filter((m) => m.To.some((to) => to.Address === RETRIED.email));
          expectEqual(all.length, 1, 'mails to the retried address');
          const delivered = await sink.message(hits[0].ID);
          expectEqual(header(delivered.Headers, 'X-Mail-Job'), [sent.jobId], 'X-Mail-Job header');
          saveMail('retried-invitation-mail', delivered);
          note('delivered after retry', { jobId: sent.jobId, attempts: sent.attempts });
        });
      }
    } finally {
      fs.writeFileSync(path.join(OUT, 'result.json'), `${JSON.stringify(evidence, null, 2)}\n`);
      await sink.close();
    }
  },
};
