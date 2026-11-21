'use strict';

const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.resolve(__dirname, '..', '..');
const E2E = path.join(ROOT, 'e2e');

const LANES = {
  1: { firestore: 8089, firestoreWebsocket: 9150, auth: 9099, hub: 4400, logging: 4500, platformApi: 18790, staff: 18791, copilot: 18765, forecast: 18766, gemini: 18767, scoutRecord: 18780 },
  2: { firestore: 8589, firestoreWebsocket: 9550, auth: 9599, hub: 4600, logging: 4700, platformApi: 18990, staff: 18991, copilot: 18965, forecast: 18966, gemini: 18967, scoutRecord: 18980 },
};
const EMULATOR_PORTS = ['firestore', 'firestoreWebsocket', 'auth', 'hub', 'logging'];

const LANE = process.env.E2E_LANE || '1';
if (!Object.hasOwn(LANES, LANE)) {
  throw new Error(`E2E_LANE must be one of ${Object.keys(LANES).join(', ')}, got "${LANE}"`);
}
const ports = LANES[LANE];
const isDefault = LANE === '1';
const scratchDir = isDefault ? null : path.join(E2E, `lane${LANE}`);
const outputRoot = isDefault ? path.join(E2E, 'output') : path.join(scratchDir, 'output');
const tmpDir = isDefault ? null : path.join(scratchDir, 'tmp');
const buildSuffix = isDefault ? '' : `_l${LANE}`;

const buildFolder = (name) => (name.endsWith(buildSuffix) ? name : `${name}${buildSuffix}`);

function firebaseConfig() {
  if (isDefault) return path.join(ROOT, 'admin_dashboard', 'firebase.json');
  const at = (port) => ({ host: '127.0.0.1', port });
  const config = {
    firestore: { rules: 'admin_dashboard/firestore.rules', indexes: 'admin_dashboard/firestore.indexes.json' },
    emulators: {
      firestore: { ...at(ports.firestore), websocketPort: ports.firestoreWebsocket },
      auth: at(ports.auth),
      hub: at(ports.hub),
      logging: at(ports.logging),
      ui: { enabled: false },
      singleProjectMode: false,
    },
  };
  const file = path.join(ROOT, `firebase.e2e.lane${LANE}.json`);
  fs.writeFileSync(file, `${JSON.stringify(config, null, 2)}\n`);
  return file;
}

const COMMANDS = {
  'emulator-ports': () => EMULATOR_PORTS.map((key) => ports[key]).join(' '),
  'all-ports': () => Object.values(ports).join(' '),
  port: (key) => {
    if (!Object.hasOwn(ports, key)) throw new Error(`no port named ${key}; known: ${Object.keys(ports).join(', ')}`);
    return String(ports[key]);
  },
  'build-folder': (name) => buildFolder(name),
  'firebase-config': () => firebaseConfig(),
  'scratch-dirs': () => {
    for (const dir of [outputRoot, tmpDir].filter(Boolean)) fs.mkdirSync(dir, { recursive: true });
    return [scratchDir || ROOT, tmpDir || '', outputRoot].join('\n');
  },
};

if (require.main === module) {
  const [command, ...args] = process.argv.slice(2);
  if (!Object.hasOwn(COMMANDS, command || '')) {
    console.error(`usage: node e2e/lib/lane.cjs ${Object.keys(COMMANDS).join('|')} [arg]`);
    process.exit(2);
  }
  process.stdout.write(COMMANDS[command](...args));
}

module.exports = { LANES, LANE, ports, isDefault, outputRoot, tmpDir, scratchDir, buildFolder, firebaseConfig };
