'use strict';

const assert = require('node:assert/strict');
const B = require('../lib/browser.cjs');
const mobile = require('../lib/mobile.cjs');
const admin = require('../lib/admin.cjs');
const E = require('../lib/emulator.cjs');
const { PRODUCTS, RETAILERS } = require('../lib/seed.cjs');

const RETAILER = RETAILERS[1];
const HIDDEN = PRODUCTS[2];
const VISIBLE_OLD = PRODUCTS[0];
const NEW_PRODUCT = {
  department: 'E2E SNACKS', category: 'E2E CRACKERS', name: 'SEA SALT CRACKER', brand: 'TENTEN',
  code: 'R900-SNK-001', price: '12.50',
};
const NEW_DISPLAY_NAME = 'SEA SALT CRACKER';

module.exports = {
  name: 'catalogue_cart',
  async run(t) {
    const { db, accounts } = t;
    let adminS;
    let mobileS;

    await t.step('retailer score sheet allows the whole catalogue', async () => {
      const sheet = await db.get('retailer_score_sheet_settings', RETAILER.id);
      await db.put('retailer_score_sheet_settings', RETAILER.id, { ...sheet, visibleProductIds: [], visibleProductCount: 0 });
    });

    await t.step('admin logs in on the dashboard', async () => {
      adminS = await t.session('admin');
      await B.loginAdmin(adminS.page, adminS.url, accounts.admin.email);
      await admin.waitForShell(adminS.page);
    });

    await t.step('admin creates a product with department and category', async () => {
      await admin.createProduct(adminS.page, NEW_PRODUCT);
      const product = await db.waitForQuery('products', (p) => p.productCode === NEW_PRODUCT.code, { label: 'new product' });
      expectEqual(product.departmentName, NEW_PRODUCT.department, 'departmentName');
      expectEqual(product.mainCategoryName, NEW_PRODUCT.category, 'mainCategoryName');
      expectEqual(product.brandName, NEW_PRODUCT.brand, 'brandName');
      expectEqual(product.unitPrice, 12.5, 'unitPrice');
      expectEqual(product.isVisible, true, 'isVisible');
      await db.waitForQuery('departments', (d) => (d.departmentName || d.name) === NEW_PRODUCT.department, { label: 'department' });
      await db.waitForQuery('categories', (c) => (c.categoryName || c.mainCategoryName || c.name) === NEW_PRODUCT.category, { label: 'category' });
      await B.see(adminS.page, NEW_DISPLAY_NAME);
      const boxOf = (name) => adminS.page.getByRole('button', { name }).first().boundingBox();
      const [options, add] = [await boxOf(/^View options$/), await boxOf(/^Add product$/)];
      assert.ok(Math.abs((options.x + options.width) - (add.x + add.width)) <= 2,
        `View options must be right-aligned with the header actions: ${options.x + options.width} vs ${add.x + add.width}`);
      assert.ok(Math.abs(options.height - 36) <= 1, `View options must be 36px high, got ${options.height}`);
      await t.shot(adminS, 'product-created');
      await t.shot(adminS, 'products-search-hint');
    });

    await t.step('duplicate product failure leaves missing parents untouched', async () => {
      E.requireEmulators();
      const department = await db.waitForQuery(
        'departments',
        (row) => (row.departmentName || row.name) === NEW_PRODUCT.department,
        { label: 'created department' },
      );
      const category = await db.waitForQuery(
        'categories',
        (row) => (row.categoryName || row.mainCategoryName || row.name) === NEW_PRODUCT.category,
        { label: 'created category' },
      );
      const originalDepartment = await db.get('departments', department.id);
      const originalCategory = await db.get('categories', category.id);
      const originalProduct = await db.waitForQuery(
        'products', (product) => product.productCode === NEW_PRODUCT.code,
        { label: 'original product before duplicate create' },
      );
      const originalProductData = await db.get('products', originalProduct.id);
      assert.ok(originalDepartment);
      assert.ok(originalCategory);

      const deleteDocument = async (collection, id) => {
        const response = await fetch(`${db.firestoreBase}/${collection}/${encodeURIComponent(id)}`, {
          method: 'DELETE', headers: { Authorization: 'Bearer owner' },
        });
        assert(response.ok, `local fixture delete ${collection}/${id}: ${response.status}`);
      };

      try {
        await deleteDocument('departments', department.id);
        await deleteDocument('categories', category.id);
        assert.equal(await db.get('departments', department.id), null);
        assert.equal(await db.get('categories', category.id), null);

        await adminS.page.getByRole('button', { name: 'Add product' }).click();
        const box = (label) => adminS.page.getByRole('textbox', { name: new RegExp(`^${label}\\b`) }).first();
        await B.fillField(adminS.page, box('Department'), NEW_PRODUCT.department);
        await B.fillField(adminS.page, box('Main Category'), NEW_PRODUCT.category);
        await B.fillField(adminS.page, box('Product'), NEW_PRODUCT.name);
        await B.fillField(adminS.page, box('Brand'), NEW_PRODUCT.brand);
        await B.fillField(adminS.page, box('Product Code'), NEW_PRODUCT.code);
        await B.fillField(adminS.page, box('Unit Price'), NEW_PRODUCT.price);
        await adminS.page.getByRole('button', { name: 'Save', exact: true }).click();
        await B.see(adminS.page, 'Could not save the product. Please try again.');

        assert.equal(await db.get('departments', department.id), null,
          'failed duplicate create left a department document behind');
        assert.equal(await db.get('categories', category.id), null,
          'failed duplicate create left a category document behind');
        assert.deepEqual(await db.get('products', originalProduct.id), originalProductData,
          'failed duplicate create changed the original product');
        await t.shot(adminS, 'duplicate-product-no-orphan-parents');
      } finally {
        await db.put('departments', department.id, originalDepartment);
        await db.put('categories', category.id, originalCategory);
      }

      await adminS.page.getByRole('button', { name: 'Cancel', exact: true }).click();
      await adminS.page.getByRole('button', { name: 'Discard', exact: true }).click();
    });

    await t.step('admin hides another product', async () => {
      await admin.setProductVisibility(adminS.page, HIDDEN.name, 'Hide');
      const product = await db.waitForDoc('products', HIDDEN.id, (p) => p.isVisible === false);
      expectEqual(product.status, 'hidden', 'status');
      await B.see(adminS.page, new RegExp(`Product ${HIDDEN.name.replace(/[()]/g, '\\$&')}, Brand TENTEN, Hidden`));
      await t.shot(adminS, 'product-hidden');
    });

    await t.step('admin changes visibility for multiple products together', async () => {
      const targets = [NEW_DISPLAY_NAME, VISIBLE_OLD.name];
      const newProduct = await db.waitForQuery(
        'products', (product) => product.productCode === NEW_PRODUCT.code,
        { label: 'new product for bulk visibility' },
      );
      await setBulkVisibility(adminS.page, targets, 'Hide');
      for (const id of [newProduct.id, VISIBLE_OLD.id]) {
        const hidden = await db.waitForDoc('products', id, (product) => product.isVisible === false);
        expectEqual(hidden.status, 'hidden', `${id} status after bulk hide`);
      }

      await setBulkVisibility(adminS.page, targets, 'Show');
      for (const id of [newProduct.id, VISIBLE_OLD.id]) {
        const visible = await db.waitForDoc('products', id, (product) => product.isVisible === true);
        expectEqual(visible.status, 'active', `${id} status after bulk show`);
      }
      await t.shot(adminS, 'products-bulk-visibility');
    });

    await t.step('salesman logs in on mobile and opens the planned visit', async () => {
      mobileS = await t.session('mobile', { viewport: mobile.MOBILE_VIEWPORT });
      await B.loginMobile(mobileS.page, mobileS.url, accounts.salesman.email);
      await mobile.waitForHome(mobileS.page);
      await mobile.planVisitToday(mobileS.page, RETAILER.name);
      await mobile.openPlannedVisit(mobileS.page, RETAILER.name);
    });

    await t.step('the new product is offered and the hidden one is not', async () => {
      const page = mobileS.page;
      await page.locator(`[aria-label="${NEW_PRODUCT.category}"]`).first().click();
      await B.see(page, NEW_DISPLAY_NAME);
      await page.locator('[aria-label="GROCERY"]').first().click();
      await B.see(page, VISIBLE_OLD.name.split(' (')[0]);
      const hiddenRows = await page.getByRole('checkbox', { name: new RegExp(HIDDEN.name.split(' (')[0]) }).count();
      expectEqual(hiddenRows, 0, `rows offered for the hidden product ${HIDDEN.name}`);
      await t.shot(mobileS, 'catalogue');
    });

    await t.step('salesman adds the new product to the cart and reaches the sign-off', async () => {
      const page = mobileS.page;
      await page.locator(`[aria-label="${NEW_PRODUCT.category}"]`).first().click();
      await page.getByRole('checkbox', { name: new RegExp(`^(?:[^\\n·]+ · )?${NEW_DISPLAY_NAME}`) }).click();
      await page.getByRole('button', { name: /^Add to Cart \(1\)/ }).click();
      await page.getByRole('button', { name: 'Start counting' }).click();
      await B.see(page, NEW_DISPLAY_NAME);
      await mobile.continueToSignature(page);
      await B.see(page, NEW_DISPLAY_NAME);
      await t.shot(mobileS, 'signoff');
    });

    await t.step('the cart stops at 5 boxes of one item', async () => {
      const page = mobileS.page;
      await B.see(page, 'Total (1 product, 1 box)');
      for (let i = 0; i < 4; i += 1) await page.getByRole('button', { name: 'Increase order quantity' }).click();
      await B.see(page, 'Total (1 product, 5 boxes)');
      await page.getByRole('button', { name: 'Increase order quantity' }).click();
      await B.see(page, 'Limit reached');
      await B.see(page, 'The maximum order quantity is 5.');
      await t.shot(mobileS, 'limit-reached');
      await page.getByRole('button', { name: 'OK', exact: true }).click();
      await B.see(page, 'Total (1 product, 5 boxes)');
    });

    await t.step('typing more than 5 boxes is capped at 5', async () => {
      const page = mobileS.page;
      const qty = page.getByRole('textbox', { name: 'Order quantity' });
      for (let i = 0; i < 2; i += 1) await page.getByRole('button', { name: 'Decrease order quantity' }).click();
      await B.see(page, 'Total (1 product, 3 boxes)');
      let capped = false;
      for (let attempt = 0; attempt < 5 && !capped; attempt += 1) {
        await qty.click();
        await page.keyboard.press('Control+A');
        await page.keyboard.type('9', { delay: 30 });
        capped = await B.see(page, 'Maximum order quantity is 5.', { timeout: 3000 })
          .then(() => true, () => false);
      }
      await B.see(page, 'Maximum order quantity is 5.');
      await page.getByRole('button', { name: 'OK', exact: true }).click();
      await B.see(page, 'Total (1 product, 5 boxes)');
    });
  },
};

function expectEqual(actual, expected, what) {
  if (actual !== expected) throw new Error(`${what}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
}

async function setBulkVisibility(page, names, action) {
  for (const name of names) {
    const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    await page.getByRole('checkbox', { name: new RegExp(`^Select ${escaped}, Brand `) }).click();
  }
  const show = action === 'Show';
  await page.getByRole('button', { name: show ? 'Show products' : 'Hide products', exact: true }).click();
  await B.see(page, `${show ? 'Showed' : 'Hid'} ${names.length} products`);
}
