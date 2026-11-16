'use strict';

const fs = require('node:fs');
const path = require('node:path');

const TIMES_FILE = path.join(__dirname, 'flow_times.json');

function resultFiles(dir) {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) return resultFiles(full);
    return entry.name === 'result.json' ? [full] : [];
  });
}

const dirs = process.argv.slice(2);
if (!dirs.length) {
  console.error('Usage: node e2e/record_flow_times.cjs <downloaded E2E evidence folder>...');
  process.exit(1);
}

const measured = {};
for (const file of dirs.flatMap(resultFiles)) {
  const result = JSON.parse(fs.readFileSync(file, 'utf8'));
  if (!result.passed || result.filtered !== false || typeof result.seconds !== 'number') continue;
  measured[result.flow] = Math.max(measured[result.flow] ?? 0, result.seconds);
}
if (!Object.keys(measured).length) {
  console.error('No passed result.json files found in ' + dirs.join(', '));
  process.exit(1);
}

const times = { ...JSON.parse(fs.readFileSync(TIMES_FILE, 'utf8')), ...measured };
const known = new Set(fs.readdirSync(path.join(__dirname, 'flows'))
  .filter((name) => name.endsWith('.spec.cjs'))
  .map((name) => name.replace(/\.spec\.cjs$/, '')));
const kept = Object.fromEntries(Object.entries(times).filter(([flow]) => known.has(flow)).sort(([a], [b]) => a.localeCompare(b)));
fs.writeFileSync(TIMES_FILE, JSON.stringify(kept, null, 2) + '\n');
console.log(`Recorded ${Object.keys(measured).length} flow times; ${Object.keys(kept).length} flows in ${path.relative(process.cwd(), TIMES_FILE)}.`);
