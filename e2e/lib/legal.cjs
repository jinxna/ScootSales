'use strict';

const fs = require('node:fs');
const path = require('node:path');

const SOURCE = path.join(__dirname, '..', '..', 'packages', 'scoot_legal', 'lib', 'src', 'legal_text.dart');
const KEYS = {
  privacyPolicy: { english: 'privacyEnglish', malay: 'privacyMalay' },
  termsAndConditions: { english: 'termsEnglish', malay: 'termsMalay' },
};
const BUTTONS = { english: 'English', malay: 'Bahasa Malaysia' };

function expectedLegal() {
  const text = fs.readFileSync(SOURCE, 'utf8');
  const version = /const String legalVersion = '([^']+)';/.exec(text)[1];
  const date = /const String legalDate = '([^']+)';/.exec(text)[1];
  const statuses = {
    english: /const String _englishStatus = '([^']+)';/.exec(text)[1],
    malay: /const String _malayStatus = '([^']+)';/.exec(text)[1],
  };
  const starts = [...text.matchAll(/const LegalText (\w+) = LegalText\(/g)];
  const blocks = {};
  starts.forEach((match, index) => {
    const end = index + 1 < starts.length ? starts[index + 1].index : text.length;
    const block = text.slice(match.index, end);
    blocks[match[1]] = {
      title: /title: '([^']+)'/.exec(block)[1],
      versionLabel: /versionLabel: '([^']+)'/.exec(block)[1],
      headings: [...block.matchAll(/LegalSection\(\s*'([^']+)'/g)].map((m) => m[1]),
    };
  });
  const documents = {};
  for (const [document, languages] of Object.entries(KEYS)) {
    documents[document] = {};
    for (const [language, key] of Object.entries(languages)) {
      const block = blocks[key];
      documents[document][language] = {
        ...block,
        versionLine: `${block.versionLabel} ${version} · ${date}`,
        status: statuses[language],
      };
    }
  }
  return { version, date, documents };
}

async function visibleLines(page) {
  return page.evaluate(() => Array.from(document.querySelectorAll('flt-semantics'))
    .map((n) => (n.getAttribute('aria-label') || n.textContent || '').trim()).filter(Boolean));
}

async function readWhileScrolling(page, wanted) {
  const size = page.viewportSize();
  await page.mouse.move(size.width / 2, size.height * 0.6);
  await page.mouse.wheel(0, -20000);
  await page.waitForTimeout(400);
  const seen = new Set();
  let quiet = 0;
  for (let step = 0; step < 80 && quiet < 4; step += 1) {
    const before = seen.size;
    for (const line of await visibleLines(page)) seen.add(line);
    if (wanted.every((item) => [...seen].some((line) => line.includes(item)))) break;
    quiet = seen.size === before ? quiet + 1 : 0;
    await page.mouse.wheel(0, 350);
    await page.waitForTimeout(250);
  }
  return [...seen];
}

async function checkLegalDocument(page, document, shot) {
  const expected = expectedLegal().documents[document];
  const report = {};
  const size = page.viewportSize();
  for (const language of ['english', 'malay']) {
    const want = expected[language];
    await page.mouse.move(size.width / 2, size.height * 0.6);
    await page.mouse.wheel(0, -20000);
    await page.waitForTimeout(300);
    await page.getByRole('button', { name: BUTTONS[language], exact: true }).first().click();
    await page.waitForTimeout(600);
    if (shot) await shot(`${document}-${language}`);
    const wanted = [want.title, want.versionLine, want.status, ...want.headings];
    const lines = await readWhileScrolling(page, wanted);
    const missing = wanted.filter((item) => !lines.some((line) => line.includes(item)));
    if (missing.length) {
      throw new Error(`${document} in ${language} is missing ${missing.length} of ${wanted.length} expected lines: ${JSON.stringify(missing.slice(0, 5))}`);
    }
    report[language] = { versionLine: want.versionLine, title: want.title, headings: want.headings.length };
  }
  await page.mouse.wheel(0, -20000);
  await page.waitForTimeout(300);
  return report;
}

module.exports = { expectedLegal, checkLegalDocument };
