'use strict';
const assert = require('node:assert/strict');
const B = require('../lib/browser.cjs');
const admin = require('../lib/admin.cjs');
const mobile = require('../lib/mobile.cjs');
const { putMany } = require('../lib/bulk.cjs');
const { PRODUCTS, RETAILERS } = require('../lib/seed.cjs');

const COUNT = 5002;
const productId = (n) => `zz-paging-${String(n).padStart(5, '0')}`;
const LAST_ID = productId(COUNT - 1);
const LAST_NAME = 'PAGING LAST PRODUCT';
const BOUNDARY_INDEX = 500 - PRODUCTS.length - 1;
const retailer = RETAILERS[1];

async function searchAdmin(page, text) {
  await B.fillField(page, page.getByRole('textbox', {
    name: 'Search products, brands, codes, barcodes', exact: true,
  }), text);
}

async function searchMobile(page, text) {
  await B.fillField(page, page.getByRole('textbox', {
    name: 'Search SKU or product...', exact: true,
  }), text);
}

module.exports = {
  name: 'catalogue_paging',
  async run(t) {
    let adminS;
    let mobileS;
    let template;
    await t.step('seed more than 5001 products with a unique last-page product', async () => {
      template = await t.db.get('products', PRODUCTS[0].id);
      await putMany(t.db, 'products', Array.from({ length: COUNT }, (_, n) => ({
        id: productId(n),
        data: {
          ...template, productId: productId(n), productCode: productId(n),
          itemCode: productId(n), itemName: n === COUNT - 1 ? LAST_NAME : `PAGING ITEM ${n}`,
          productName: n === COUNT - 1 ? LAST_NAME : `PAGING ITEM ${n}`,
          packingSize: 'PAGING PACK', status: 'active', isVisible: true,
          unitPrice: 12.5, sortOrder: n,
        },
      })));
      const settings = await t.db.get('retailer_score_sheet_settings', retailer.id);
      await t.db.put('retailer_score_sheet_settings', retailer.id, {
        ...settings, visibleProductIds: [], hiddenProductIds: [], disabledProductIds: [],
        productOverrides: {},
      });
      assert(COUNT > 5001);
    });
    await t.step('dashboard local search includes the final cursor page', async () => {
      adminS = await t.session('admin');
      await B.loginAdmin(adminS.page, adminS.url, t.accounts.admin.email);
      await admin.waitForShell(adminS.page);
      await admin.goToPage(adminS.page, 'Products');
      await searchAdmin(adminS.page, LAST_NAME);
      await B.see(adminS.page, LAST_NAME, { timeout: 60000 });
      await t.shot(adminS, 'admin-last-page-search');
    });
    await t.step('mobile local search includes the final page after retailer settings', async () => {
      mobileS = await t.session('mobile', { viewport: mobile.MOBILE_VIEWPORT });
      await B.loginMobile(mobileS.page, mobileS.url, t.accounts.salesman.email);
      await mobile.waitForHome(mobileS.page);
      await mobile.planVisitToday(mobileS.page, retailer.name);
      await mobile.openPlannedVisit(mobileS.page, retailer.name);
      await searchMobile(mobileS.page, LAST_NAME);
      await mobileS.page.getByRole('checkbox', { name: /PAGING LAST PRODUCT/ }).waitFor({ timeout: 60000 });
      await t.shot(mobileS, 'mobile-last-page-search');
    });
    await t.step('a tail-page price update reaches both apps without reopening', async () => {
      const product = await t.db.get('products', LAST_ID);
      await t.db.put('products', LAST_ID, { ...product, unitPrice: 37.25 });
      await B.see(adminS.page, /37\.25/);
      await B.see(mobileS.page, /37\.25/, { timeout: 60000 });
      await t.shot(mobileS, 'tail-price-live');
    });
    await t.step('boundary insertion and deletion keep a displaced product searchable', async () => {
      const inserted = { ...template, productId: '00-paging-insert', itemName: 'PAGING INSERTED',
        productName: 'PAGING INSERTED', unitPrice: 9.75, isVisible: true, status: 'active' };
      await t.db.put('products', '00-paging-insert', inserted);
      await searchAdmin(adminS.page, 'PAGING INSERTED');
      await searchMobile(mobileS.page, 'PAGING INSERTED');
      await B.see(adminS.page, 'PAGING INSERTED');
      await mobileS.page.getByRole('checkbox', { name: /PAGING INSERTED/ }).waitFor();
      const boundaryName = `PAGING ITEM ${BOUNDARY_INDEX}`;
      await searchAdmin(adminS.page, productId(BOUNDARY_INDEX));
      await B.see(adminS.page, boundaryName);
      await searchMobile(mobileS.page, boundaryName);
      await mobileS.page.getByRole('checkbox', {
        name: new RegExp(`${boundaryName}(?!\\d)`),
      }).waitFor();
      await t.db.del('products', '00-paging-insert');
      await searchAdmin(adminS.page, LAST_NAME);
      await searchMobile(mobileS.page, LAST_NAME);
      await B.see(adminS.page, LAST_NAME);
      await mobileS.page.getByRole('checkbox', { name: /PAGING LAST PRODUCT/ }).waitFor();
      await t.shot(adminS, 'boundary-rebuilt');
    });
    await t.step('live retailer hide and product status still gate the final page', async () => {
      const settings = await t.db.get('retailer_score_sheet_settings', retailer.id);
      await t.db.put('retailer_score_sheet_settings', retailer.id, { ...settings, hiddenProductIds: [LAST_ID] });
      await mobileS.page.getByRole('checkbox', { name: /PAGING LAST PRODUCT/ }).waitFor({ state: 'detached' });
      await B.see(mobileS.page, 'No products found');
      await t.db.put('retailer_score_sheet_settings', retailer.id, settings);
      await mobileS.page.getByRole('checkbox', { name: /PAGING LAST PRODUCT/ }).waitFor();
      const product = await t.db.get('products', LAST_ID);
      await t.db.put('products', LAST_ID, { ...product, status: 'archived' });
      await mobileS.page.getByRole('checkbox', { name: /PAGING LAST PRODUCT/ }).waitFor({ state: 'detached' });
      await B.see(mobileS.page, 'No products found');
      await t.shot(mobileS, 'tail-hidden-live');
    });
  },
};
