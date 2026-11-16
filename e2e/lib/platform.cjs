'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const E = require('./emulator.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const KEY_DIR = path.resolve(__dirname, '..', '.keys');
const PYTHON = process.env.E2E_PYTHON || (process.platform === 'win32' ? 'python' : 'python3');
const KEY_ID = 'e2e-1';
const OTHER_KEY_ID = 'e2e-2';

const PLATFORM_API_PORT = Number(process.env.PLATFORM_API_PORT) || 18790;
const PLATFORM_API_URL = `http://127.0.0.1:${PLATFORM_API_PORT}`;

const SERVICES = { copilotUrl: 'http://127.0.0.1:18765', forecastingUrl: 'http://127.0.0.1:18766' };

function python(args, { input, env } = {}) {
  const result = spawnSync(PYTHON, args, {
    cwd: ROOT, input, encoding: 'utf8', maxBuffer: 16 * 1024 * 1024, windowsHide: true,
    env: { ...process.env, PYTHONWARNINGS: 'ignore', PYTHONIOENCODING: 'utf-8', ...env },
  });
  if (result.error) throw new Error(`could not run ${PYTHON}: ${result.error.message}`);
  if (result.status !== 0) throw new Error(`${PYTHON} ${args.join(' ')} failed:\n${result.stderr || result.stdout}`);
  return result.stdout;
}

function ensureKey(keyId = KEY_ID) {
  const file = path.join(KEY_DIR, `${keyId}.json`);
  if (!fs.existsSync(file)) {
    fs.mkdirSync(KEY_DIR, { recursive: true });
    python(['-m', 'platform_service.devtool', 'keygen', '--key-id', keyId, '--out', file]);
  }
  const key = JSON.parse(fs.readFileSync(file, 'utf8'));
  return { keyId: key.keyId, file, publicKey: key.publicKey, seed: key.seed };
}

const publicKeysText = (...keys) => keys.map((k) => `${k.keyId}=${k.publicKey}`).join(',');

function baseRecord(project = E.PROJECT) {
  const records = JSON.parse(python(['-m', 'platform_service.seed_directory']));
  const record = records.find((r) => r.location.projectId === project);
  if (!record) throw new Error(`seed_directory has no record for project ${project}`);
  return record;
}

function signRecord(record, key, version = 1) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'e2e-record-'));
  try {
    const file = path.join(dir, 'record.json');
    fs.writeFileSync(file, JSON.stringify(record));
    return JSON.parse(python([
      '-m', 'platform_service.devtool', 'sign-record',
      '--key-file', key.file, '--version', String(version), '--record-json', file,
    ]));
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

function harnessRecord() {
  return {
    ...baseRecord(),
    status: 'active',
    planRef: process.env.E2E_EDITION === 'basic' ? 'P1' : 'P2',
    edition: process.env.E2E_EDITION === 'basic' ? 'basic' : 'advanced',
    services: SERVICES,
  };
}

const harnessWorkspaceEnvelope = () => signRecord(harnessRecord(), ensureKey());

module.exports = {
  ROOT, PYTHON, KEY_ID, OTHER_KEY_ID, PLATFORM_API_PORT, PLATFORM_API_URL, SERVICES,
  python, ensureKey, publicKeysText, baseRecord, signRecord, harnessRecord, harnessWorkspaceEnvelope,
};
