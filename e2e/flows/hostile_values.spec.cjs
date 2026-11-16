'use strict';

const B = require('../lib/browser.cjs');
const admin = require('../lib/admin.cjs');
const mobile = require('../lib/mobile.cjs');
const { RETAILERS, PRODUCTS } = require('../lib/seed.cjs');

const ORDER_ID = 'ORD-TEXT-NUMBERS';

module.exports = {
  name: 'hostile_values',
  async run(t) {
    const { db, accounts, seed } = t;
    let s;

    await t.step('seed an order whose numbers are stored as text', async () => {
      const uid = seed.uids.salesman;
      const retailer = RETAILERS[0];
      await db.put('orders', ORDER_ID, {
        orderId: ORDER_ID, retailerId: retailer.id, retailerName: retailer.name, outlet: retailer.name, branchId: 'B1',
        uid, userUid: uid, salesmanUid: uid, salesmanCode: accounts.salesman.code, status: 'submitted',
        totalProducts: '1', totalBoxes: '2', totalPrice: 'RM 1,234.50',
        latitude: '1.5312', longitude: '110.3609',
        items: [{ productId: PRODUCTS[0].id, productName: PRODUCTS[0].name, department: PRODUCTS[0].dept, qty: '2', unitPrice: '617.25', shelfBatches: [] }],
        submittedAt: new Date(), createdAt: new Date(),
      });
      const p = PRODUCTS[0];
      await db.put('products', p.id, {
        productId: p.id, itemCode: p.code, productCode: p.code, itemName: p.name, productName: p.name,
        barcode: p.barcode, itemBarcode: p.barcode, packagingSpecification: '24 X 500ML',
        unitPrice: 'RM 28.12', brandName: 'TENTEN', brand: 'TENTEN',
        departmentName: p.dept, mainCategoryName: p.dept, sortOrder: 0, isVisible: true,
      });
    });

    await t.step('All Orders shows the order and its total', async () => {
      s = await t.session('admin');
      await B.loginAdmin(s.page, s.url, accounts.admin.email);
      await admin.waitForShell(s.page);
      await admin.goToPage(s.page, 'All Orders');
      await B.see(s.page, /RM 1,?234\.50/);
    });

    await t.step('the order details dialog reads the text quantities and prices', async () => {
      await admin.openOrder(s.page, ORDER_ID);
      await B.see(s.page, PRODUCTS[0].name);
      await t.shot(s, 'order-details');
      await s.page.keyboard.press('Escape');
    });

    await t.step('Reports reads the same order', async () => {
      await admin.goToPage(s.page, 'Reports');
      await s.page.waitForTimeout(2500);
      await t.shot(s, 'reports');
    });

    await t.step('the mobile cart takes a product whose price is text', async () => {
      const m = await t.session('mobile', { viewport: mobile.MOBILE_VIEWPORT });
      await B.loginMobile(m.page, m.url, accounts.salesman.email);
      await mobile.waitForHome(m.page);
      await mobile.planVisitToday(m.page, RETAILERS[0].name);
      await mobile.openPlannedVisit(m.page, RETAILERS[0].name);
      await mobile.selectProducts(m.page, PRODUCTS[0].dept, [PRODUCTS[0].name]);
      await m.page.getByRole('button', { name: 'Continue to Signature' }).waitFor({ timeout: 20000 });
      await t.shot(m, 'cart');
    });
  },
};
