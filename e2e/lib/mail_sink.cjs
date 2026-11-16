'use strict';

const fs = require('node:fs');
const path = require('node:path');
const E = require('./emulator.cjs');

const STUB_FILE = path.join(E.OUTPUT_DIR, 'mail_stub', 'mail.jsonl');
const DOWN_FILE = `${STUB_FILE}.down`;
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function records() {
  let text = '';
  try { text = fs.readFileSync(STUB_FILE, 'utf8'); } catch { return []; }
  const rows = [];
  for (const line of text.split('\n')) {
    if (!line.trim()) continue;
    try { rows.push(JSON.parse(line)); } catch { }
  }
  return rows;
}

function summary(row) {
  return {
    ID: row.id,
    MessageID: row.messageId,
    From: { Name: '', Address: row.from },
    To: row.request.to.map((to) => ({ Name: '', Address: to.email })),
    Subject: row.rendered.subject,
    Created: row.createdAt,
  };
}

function remove(file) {
  try { fs.unlinkSync(file); } catch { }
}

async function startMailSink() {
  fs.mkdirSync(path.dirname(STUB_FILE), { recursive: true });
  remove(DOWN_FILE);
  return {
    file: STUB_FILE,
    external: false,
    async stop() { fs.writeFileSync(DOWN_FILE, ''); },
    async restart() { remove(DOWN_FILE); },
    async close() { remove(DOWN_FILE); },
    async clear() { fs.writeFileSync(STUB_FILE, ''); },
    async messages() { return records().reverse().map(summary); },
    async message(id) {
      const row = records().find((candidate) => candidate.id === id);
      if (!row) throw new Error(`mail stub has no message ${id}`);
      return {
        ...summary(row),
        Text: row.rendered.text,
        HTML: row.rendered.html,
        Headers: Object.fromEntries(Object.entries(row.request.headers).map(([name, value]) => [name, [value]])),
        Stub: { template: row.template, request: row.request },
        Attachments: row.attachments || [],
      };
    },
    async waitForMessage(recipient, { timeout = 60000 } = {}) {
      const deadline = Date.now() + timeout;
      let last = [];
      while (Date.now() < deadline) {
        last = await this.messages();
        const hits = last.filter((m) => m.To.some((to) => to.Address.toLowerCase() === recipient.toLowerCase()));
        if (hits.length) return hits;
        await sleep(250);
      }
      throw new Error(`no mail to ${recipient} reached the mail stub within ${timeout} ms; it holds ${JSON.stringify(last.map((m) => m.To))}`);
    },
    async waitForEmailCode(recipient, { timeout = 60000, ignore = [] } = {}) {
      const deadline = Date.now() + timeout;
      while (Date.now() < deadline) {
        const hits = (await this.messages()).filter((m) => m.To.some((to) => to.Address.toLowerCase() === recipient.toLowerCase()));
        for (const hit of hits) {
          const match = /code is (\d{6})/.exec((await this.message(hit.ID)).Text);
          if (match && !ignore.includes(match[1])) return match[1];
        }
        await sleep(250);
      }
      throw new Error(`no email code mail to ${recipient} within ${timeout} ms`);
    },
  };
}

module.exports = { startMailSink, STUB_FILE };
