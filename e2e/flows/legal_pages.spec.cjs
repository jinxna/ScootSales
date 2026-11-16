'use strict';

const fs = require('node:fs');
const path = require('node:path');
const B = require('../lib/browser.cjs');
const E = require('../lib/emulator.cjs');
const admin = require('../lib/admin.cjs');
const mobile = require('../lib/mobile.cjs');
const { expectedLegal, checkLegalDocument } = require('../lib/legal.cjs');

const DOCUMENTS = [
  ['privacyPolicy', 'Privacy Policy'],
  ['termsAndConditions', 'Terms & Conditions'],
];

module.exports = {
  name: 'legal_pages',
  async run(t) {
    const { accounts } = t;
    const expected = expectedLegal();
    const seen = { source: { version: expected.version, date: expected.date }, dashboard: {}, phone: {} };

    await t.step('the dashboard shows both documents in English and Bahasa Malaysia', async () => {
      const s = await t.session('admin');
      await B.loginAdmin(s.page, s.url, accounts.admin.email);
      await admin.waitForShell(s.page);
      for (const [document, label] of DOCUMENTS) {
        await admin.goToPage(s.page, label);
        seen.dashboard[document] = await checkLegalDocument(s.page, document, (name) => t.shot(s, `dashboard-${name}`));
      }
    });

    await t.step('the signed-out phone shows both documents in English and Bahasa Malaysia', async () => {
      const phone = await t.session('mobile', { viewport: mobile.MOBILE_VIEWPORT });
      await B.openApp(phone.page, phone.url);
      for (const [document, label] of DOCUMENTS) {
        await phone.page.getByRole('button', { name: label, exact: true }).first().click({ timeout: 60000 });
        await phone.page.waitForTimeout(800);
        seen.phone[document] = await checkLegalDocument(phone.page, document, (name) => t.shot(phone, `phone-${name}`));
        await phone.page.getByRole('button', { name: 'Back' }).first().click();
        await phone.page.waitForTimeout(800);
      }
    });

    await t.step('both apps show the same version as the shared source', async () => {
      const lines = [];
      for (const app of ['dashboard', 'phone']) {
        for (const [document] of DOCUMENTS) {
          for (const language of ['english', 'malay']) {
            lines.push(`${app} ${document} ${language}: ${seen[app][document][language].versionLine}`);
          }
        }
      }
      const versions = new Set(lines.map((line) => line.split(': ')[1].replace(/^\S+ /, '')));
      if (versions.size !== 1) throw new Error(`the apps show different versions: ${lines.join('; ')}`);
      const outDir = path.join(E.OUTPUT_DIR, 'legal_pages');
      fs.mkdirSync(outDir, { recursive: true });
      fs.writeFileSync(path.join(outDir, 'result.json'), JSON.stringify({ generatedAt: new Date().toISOString(), ...seen, lines }, null, 2));
    });
  },
};
