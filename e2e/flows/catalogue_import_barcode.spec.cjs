'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const B = require('../lib/browser.cjs');
const admin = require('../lib/admin.cjs');
const E = require('../lib/emulator.cjs');

const HEADER = 'Product ID,Department,Category,Product,Barcode,Price,Status';
const csvRow = (id, barcode, price = 12.5, status = '') =>
  `${id},BARCODE IMPORT,Acceptance,${id},${barcode},${price},${status}`;

async function upload(page, name, rows, warningCount) {
  const chooserPromise = page.waitForEvent('filechooser');
  await page.getByRole('button', { name: 'Upload and preview', exact: true }).click();
  const chooser = await chooserPromise;
  await chooser.setFiles({
    name: `${name}.csv`, mimeType: 'text/csv',
    buffer: Buffer.from([HEADER, ...rows].join('\n'), 'utf8'),
  });
  await B.see(page, `${name}.csv`);
  await B.see(page, `${rows.length} rows`);
  await B.see(page, '0 invalid');
  await B.see(page, `${warningCount} with warnings`);
  const duplicate = B.semantic(page, /Duplicate active barcode "/);
  assert.equal(await duplicate.count() > 0, warningCount > 0, 'duplicate warning presence');
  const confirm = page.getByRole('button', { name: 'Confirm batch import', exact: true });
  assert.equal(await confirm.isEnabled(), true, 'review warnings must not reject valid rows');
}

module.exports = {
  name: 'catalogue_import_barcode',
  async run(t) {
    E.requireEmulators();
    const { db, accounts } = t;
    let session;
    const evidence = [];

    await t.step('seed barcode fixtures only in local emulators', async () => {
      for (const [id, barcode, status] of [
        ['barcode_existing', '012345678905', 'active'],
        ['barcode_self', '96385074', 'active'],
        ['barcode_archived', '10012345000017', 'archived'],
        ['barcode_hidden', '10012345000017', 'hidden'],
        ['barcode_discontinued', '10012345000017', 'discontinued'],
        ['barcode_invisible', '10012345000017', 'active'],
      ]) {
        await db.put('products', id, {
          productId: id, productName: id, itemName: id,
          departmentId: 'barcode_import', departmentName: 'BARCODE IMPORT',
          categoryId: 'barcode_import_acceptance', mainCategoryName: 'Acceptance',
          itemBarcode: barcode, barcode, status,
          isVisible: id !== 'barcode_invisible', unitPrice: 10, price: 10,
          brandName: 'TENTEN', uom: 'ctn',
        });
      }
    });

    await t.step('admin opens the import centre', async () => {
      session = await t.session('admin');
      await B.loginAdmin(session.page, session.url, accounts.admin.email);
      await admin.waitForShell(session.page);
      await admin.goToPage(session.page, 'Import Centre');
      await B.see(session.page, 'Batch import');
    });

    await t.step('existing equivalent GTIN reports a review warning without writes', async () => {
      await upload(session.page, 'existing-collision', [
        csvRow('barcode_existing_collision', '0012345678905'),
      ], 1);
      await B.see(session.page, /Duplicate active barcode "00012345678905".*barcode_existing/);
      await B.see(session.page, /Warnings do not block import\./);
      await B.see(session.page, 'Review');
      assert.equal(await db.get('products', 'barcode_existing_collision'), null);
      await t.shot(session, 'existing-active-duplicate-review');
      evidence.push({ case: 'existing-active', warningRows: 1, previewWrites: 0 });
    });

    await t.step('explicit confirmation permits the reviewed duplicate', async () => {
      await session.page.getByRole('button', { name: 'Confirm batch import', exact: true }).click();
      await B.see(session.page, 'Import completed: 1 row(s).');
      const imported = await db.waitForDoc('products', 'barcode_existing_collision',
        (row) => row.barcode === '0012345678905');
      assert.equal(imported.unitPrice, 12.5);
      const existing = await db.get('products', 'barcode_existing');
      assert.equal(existing.barcode, '012345678905', 'original product remains distinct');
      await t.shot(session, 'reviewed-duplicate-confirmed');
      evidence.push({ case: 'review-confirmed', productId: imported.productId });
    });

    await t.step('UPC-E and UPC-A within a batch both require review', async () => {
      await upload(session.page, 'batch-collision', [
        csvRow('barcode_batch_a', '03456703'),
        csvRow('barcode_batch_b', '034000005673'),
      ], 2);
      await B.see(session.page, /Duplicate active barcode "00034000005673".*barcode_batch_b/);
      await B.see(session.page, /Duplicate active barcode "00034000005673".*barcode_batch_a/);
      assert.equal(await db.get('products', 'barcode_batch_a'), null);
      assert.equal(await db.get('products', 'barcode_batch_b'), null);
      await t.shot(session, 'within-batch-upce-upca-duplicate-review');
      evidence.push({ case: 'within-batch-upce-upca', warningRows: 2, previewWrites: 0 });
    });

    await t.step('same-product update does not warn and preserves update opt-in', async () => {
      await upload(session.page, 'self-update', [csvRow('barcode_self', '96385074', 15)], 0);
      await session.page.getByRole('button', { name: 'Confirm batch import', exact: true }).click();
      await B.see(session.page, /Existing records are present\. Enable explicit updates/);
      assert.equal((await db.get('products', 'barcode_self')).unitPrice, 10);
      await session.page.getByRole('checkbox', {
        name: /Allow explicit merge updates to existing records/,
      }).click();
      await session.page.getByRole('button', { name: 'Confirm batch import', exact: true }).click();
      await B.see(session.page, 'Import completed: 1 row(s).');
      await db.waitForDoc('products', 'barcode_self', (row) => row.unitPrice === 15);
      await t.shot(session, 'self-update-no-duplicate');
      evidence.push({ case: 'self-update', warningRows: 0, explicitUpdatesRequired: true });
    });

    await t.step('unavailable existing products do not cause duplicate warnings', async () => {
      await upload(session.page, 'inactive-existing', [
        csvRow('barcode_available_new', '10012345000017'),
      ], 0);
      assert.equal(await db.get('products', 'barcode_available_new'), null);
      await t.shot(session, 'inactive-products-excluded');
      evidence.push({ case: 'inactive-existing', warningRows: 0, previewWrites: 0 });
    });

    await t.step('inactive batch updates retain omitted barcode and visibility fields', async () => {
      await upload(session.page, 'inactive-updates', [
        csvRow('barcode_archived', ''),
        csvRow('barcode_available_new', '10012345000017'),
        csvRow('barcode_hidden_new', '10012345000017', 12.5, 'hidden'),
      ], 0);
      const archived = await db.get('products', 'barcode_archived');
      assert.equal(archived.status, 'archived');
      assert.equal(archived.barcode, '10012345000017');
      assert.equal(await db.get('products', 'barcode_hidden_new'), null);
      await t.shot(session, 'inactive-merged-updates-excluded');
      evidence.push({ case: 'inactive-merged-updates', warningRows: 0, previewWrites: 0 });
    });

    const outDir = path.join(E.OUTPUT_DIR, 'catalogue_import_barcode');
    fs.mkdirSync(outDir, { recursive: true });
    fs.writeFileSync(path.join(outDir, 'barcode-import-evidence.json'),
      JSON.stringify({ flow: 'catalogue_import_barcode', cases: evidence }, null, 2) + '\n');
  },
};
