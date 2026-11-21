'use strict';

const http = require('node:http');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { ANSWERS, PORT } = require('./copilot_server.cjs');

const ROOT = path.join(__dirname, '..', '..');
const PYTHON = process.env.E2E_PYTHON || (process.platform === 'win32' ? 'python' : 'python3');
const GEMINI_PORT = require('./lane.cjs').ports.gemini;
const KEY = 'e2e-fake-gemini-key';
const DAILY_LIMIT = 3;
const HELD_SECONDS = 30;

function startFakeGemini() {
  const state = { mode: 'ok', delayMs: 0, requests: [], wrongKey: 0 };
  const sockets = new Set();
  const server = http.createServer((req, res) => {
    let raw = '';
    req.on('data', (chunk) => { raw += chunk; });
    req.on('end', () => {
      const route = /^\/v1beta\/models\/[^/]+:generateContent$/.test(req.url);
      if (req.method !== 'POST' || !route) {
        res.writeHead(404);
        return res.end();
      }
      if (req.headers['x-goog-api-key'] !== KEY) state.wrongKey += 1;
      const text = JSON.parse(raw).contents[0].parts[0].text;
      state.requests.push({ text, mode: state.mode });
      if (state.mode === 'hang') return setTimeout(() => res.destroy(), HELD_SECONDS * 1000).unref();
      if (state.mode === 'down') {
        res.writeHead(503, { 'Content-Type': 'application/json' });
        return res.end(JSON.stringify({ error: { code: 503, status: 'UNAVAILABLE' } }));
      }
      const call = ANSWERS[text.toLowerCase()] || { name: 'no_match', args: {} };
      setTimeout(() => {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ candidates: [{ content: { parts: [{ functionCall: call }] } }] }));
      }, state.delayMs);
    });
  });
  server.on('connection', (socket) => {
    sockets.add(socket);
    socket.on('close', () => sockets.delete(socket));
  });
  return new Promise((resolve) => server.listen(GEMINI_PORT, '127.0.0.1', () => resolve({
    state,
    close: () => new Promise((done) => {
      for (const socket of sockets) socket.destroy();
      server.close(done);
    }),
  })));
}

async function waitReady(url, child) {
  const deadline = Date.now() + 20000;
  while (Date.now() < deadline) {
    if (child.exitCode !== null) throw new Error(`the copilot server exited with code ${child.exitCode}`);
    const ready = await fetch(`${url}/health`).then((r) => r.ok, () => false);
    if (ready) return;
    await new Promise((r) => setTimeout(r, 200));
  }
  throw new Error('the copilot server did not become ready');
}

async function start({ origin }) {
  const gemini = await startFakeGemini();
  const env = {
    ...process.env,
    PORT: String(PORT),
    COPILOT_HOST: '127.0.0.1',
    FIREBASE_PROJECT_ID: 'cos40005',
    COPILOT_THRESHOLD: '0.996',
    ALLOWED_ORIGINS: origin,
    COPILOT_MODEL_ENABLED: '0',
    GEMINI_API_KEY: KEY,
    GEMINI_BASE_URL: `http://127.0.0.1:${GEMINI_PORT}/v1beta`,
    GEMINI_DAILY_LIMIT: String(DAILY_LIMIT),
    COPILOT_REQUEST_TIMEOUT: '9',
    PYTHONWARNINGS: 'ignore',
  };
  const child = spawn(PYTHON, [path.join(__dirname, 'copilot_gemini_only.py')], { cwd: ROOT, env, stdio: 'ignore', windowsHide: true });
  const url = `http://127.0.0.1:${PORT}`;
  try {
    await waitReady(url, child);
  } catch (error) {
    child.kill();
    await gemini.close();
    throw error;
  }
  return {
    url,
    gemini: gemini.state,
    DAILY_LIMIT,
    async close() {
      child.kill();
      await gemini.close();
    },
  };
}

module.exports = { start, DAILY_LIMIT };
