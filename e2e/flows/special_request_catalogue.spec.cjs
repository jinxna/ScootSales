'use strict';

const B = require('../lib/browser.cjs');
const admin = require('../lib/admin.cjs');
const { RETAILERS } = require('../lib/seed.cjs');

const TAKEN_ID = 'special_requests_cable_a';

module.exports = {
  name: 'special_request_catalogue',
  async run(t) {
    const { db, accounts, seed } = t;
    const retailer = RETAILERS[0];
    let s;

    const seedRequest = async (orderId, item) => {
      const uid = seed.uids.salesman;
      await db.put('orders', orderId, {
        orderId, retailerId: retailer.id, retailerName: retailer.name, outlet: retailer.name, branchId: 'B1',
        uid, userUid: uid, salesmanUid: uid, salesmanCode: accounts.salesman.code, status: 'submitted',
        totalProducts: 0, totalBoxes: 0, totalPrice: 0, items: [], submittedAt: new Date(), createdAt: new Date(),
      });
      const now = new Date();
      await db.put('special_requests', orderId, {
        orderId, requestType: 'non_catalogue_item', retailerName: retailer.name, retailerId: retailer.id,
        requestedItem: item, reason: item, salesmanCode: accounts.salesman.code, branchId: 'B1',
        createdByUid: uid, createdByRole: 'salesman', status: 'approved', approvalStep: 'Admin',
        lastActorUid: uid, lastActorRole: 'salesman', createdAt: now, updatedAt: now, lastActionAt: now,
      });
    };

    await t.step('seed a product that holds the generated ID and a request for a different name', async () => {
      await db.put('products', TAKEN_ID, {
        productId: TAKEN_ID, itemName: 'Cable-A', productName: 'Cable-A', departmentName: 'Other',
        mainCategoryName: 'Special requests', unitPrice: 12.5, uom: 'ctn', isVisible: true, status: 'active',
      });
      await seedRequest('ORD-SR-DIFFERENT', 'Cable A');
    });

    await t.step('a different name is added as its own product', async () => {
      s = await t.session('admin');
      await B.loginAdmin(s.page, s.url, accounts.admin.email);
      await admin.waitForShell(s.page);
      await admin.goToPage(s.page, 'Special Requests');
      await s.page.getByRole('button', { name: 'Add to catalogue' }).click();
      await B.see(s.page, /Request approved/);
      const request = await db.get('special_requests', 'ORD-SR-DIFFERENT');
      if (!request.catalogueProductId || request.catalogueProductId === TAKEN_ID) {
        throw new Error(`expected a new product ID, got ${JSON.stringify(request.catalogueProductId)}`);
      }
      const added = await db.get('products', request.catalogueProductId);
      if (added?.itemName !== 'Cable A') throw new Error(`new product name: ${JSON.stringify(added?.itemName)}`);
      const kept = await db.get('products', TAKEN_ID);
      if (kept.itemName !== 'Cable-A' || kept.unitPrice !== 12.5) throw new Error('the existing product was changed');
      await t.shot(s, 'different-name-added');
    });

    await t.step('the same name opens the picker and reuses the existing product', async () => {
      await seedRequest('ORD-SR-SAME', 'cable-a');
      await s.page.getByRole('button', { name: 'Add to catalogue' }).click();
      await B.see(s.page, 'Choose the existing product');
      await t.shot(s, 'picker');
      await B.semantic(s.page, TAKEN_ID).click();
      let productId;
      for (let i = 0; i < 30 && !productId; i++) {
        productId = (await db.get('special_requests', 'ORD-SR-SAME')).catalogueProductId;
        if (!productId) await s.page.waitForTimeout(500);
      }
      if (productId !== TAKEN_ID) throw new Error(`expected ${TAKEN_ID}, got ${JSON.stringify(productId)}`);
    });
  },
};
