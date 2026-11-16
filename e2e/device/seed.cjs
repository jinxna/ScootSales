'use strict';

const fs = require('node:fs');
const path = require('node:path');
const E = require('./emulator_legacy.cjs');
const { str, num, dbl, bool, arr, map, ts } = E;

const ROUTE_ID = 'route-e2e-1';
const STOP_ID = 'stop-1';
const STOP_RETAILER = 'ret-2';

const PEOPLE = [
  { email: E.ADMIN_EMAIL, name: 'E2E Admin', role: 'admin', code: 'ADM-E2E', branch: 'B1' },
  { email: E.SALES_EMAIL, name: 'E2E Salesperson', role: 'salesman', code: 'S001', branch: 'B1' },
];

const PRODUCTS = [
  { id: 'prod-1', name: 'ORGANIC APPLE CIDER VINEGAR (12BTL X 946ML)', barcode: '9555592203502', code: 'R001-BEV-001', dept: 'GROCERY', price: 28.12 },
  { id: 'prod-2', name: 'INSTANT BABY OAT (24P X 450G)', barcode: '9555592202598', code: 'R002-ORG-002', dept: 'BABY PRODUCTS', price: 9.01 },
  { id: 'prod-3', name: 'REGULAR ROLLED OAT (24P X 450G)', barcode: '9555592202611', code: 'R003-ORG-003', dept: 'GROCERY', price: 9.01 },
];

const RETAILERS = [
  { id: 'ret-1', name: 'Choice Supermarket Tabuan Jaya', area: 'Tabuan', lat: 1.5312, lng: 110.3609 },
  { id: 'ret-2', name: 'Emart Moyan', area: 'Moyan', lat: 1.5535, lng: 110.3593 },
];

async function putPerson(db, person) {
  const { uid } = await db.ensureUser(person.email, person.name);
  await db.put('users', person.email, {
    uid: str(uid), userUid: str(uid), name: str(person.name), email: str(person.email),
    role: str(person.role), user_group: str(person.role), status: str('active'),
    employeeCode: str(person.code), userId: str(person.code),
    branchId: str(person.branch), branch_id: str(person.branch),
    contactNumber: str('0123456789'),
    ...(person.role === 'salesman' ? { gpsAutofill: bool(person.gps === true) } : {}),
  });
  await db.put('user_access', uid, {
    accessVersion: num(2),
    uid: str(uid), userDocId: str(person.email), employeeCode: str(person.code),
    userId: str(person.code), email: str(person.email), role: str(person.role),
    user_group: str(person.role), status: str('active'),
    branchId: str(person.branch), branch_id: str(person.branch),
    supervisorUid: str(person.supervisorUid || ''),
    seatClass: str(person.role === 'salesman' ? 'salesperson' : 'free'),
  });
  return uid;
}

async function seed() {
  const db = E.client();
  const uids = {};
  for (const person of PEOPLE) uids[person.role] = await putPerson(db, person);

  for (const p of PRODUCTS) {
    await db.put('products', p.id, {
      productId: str(p.id), itemCode: str(p.code), productCode: str(p.code),
      itemName: str(p.name), productName: str(p.name), barcode: str(p.barcode),
      itemBarcode: str(p.barcode), packagingSpecification: str('24 X 500ML'),
      unitPrice: dbl(p.price), brandName: str('TENTEN'), brand: str('TENTEN'),
      departmentName: str(p.dept), mainCategoryName: str(p.dept),
      sortOrder: num(0), isVisible: bool(true),
    });
  }

  for (const r of RETAILERS) {
    await db.put('retailers', r.id, {
      retailerId: str(r.id), retailerName: str(r.name), name: str(r.name),
      area: str(r.area), branchId: str('B1'), status: str('active'),
      address: str(r.area + ', Kuching'), latitude: dbl(r.lat), longitude: dbl(r.lng),
      coordinateStatus: str('verified'), coordinateReviewStatus: str('reviewed'),
    });
    await db.put('retailer_score_sheet_settings', r.id, {
      retailerId: str(r.id), retailerName: str(r.name),
      visibleProductIds: arr(PRODUCTS.map((p) => str(p.id))),
      hiddenProductIds: arr([]), disabledProductIds: arr([]),
      productCount: num(PRODUCTS.length), visibleProductCount: num(PRODUCTS.length),
      sheetName: str(r.name + ' Score Sheet'),
    });
  }

  const now = new Date();
  const dayStart = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()));
  const weekStart = new Date(dayStart.getTime() - 6 * 86400000);
  const weekEnd = new Date(dayStart.getTime() + 86400000);
  const stopRetailer = RETAILERS.find((r) => r.id === STOP_RETAILER);
  await db.put('route_plans', ROUTE_ID, {
    planId: str(ROUTE_ID), createdByUid: str(uids.admin),
    salesmanUid: str(uids.salesman), salesmanCode: str('S001'),
    salesmanName: str('E2E Salesperson'), branchId: str('B1'),
    weekStart: ts(weekStart.toISOString()), weekEnd: ts(weekEnd.toISOString()),
    publishedAt: ts(now.toISOString()), status: str('published'), source: str('dashboard'),
    totalStops: num(1), stopIds: arr([str(STOP_ID)]),
    stopRetailerIds: map({ [STOP_ID]: str(STOP_RETAILER) }),
    days: arr([map({
      dayId: str('day-1'), dayLabel: str('Today'), date: ts(dayStart.toISOString()),
      totalDistanceKm: dbl(8.4),
      stops: arr([map({
        stopId: str(STOP_ID), dayId: str('day-1'), retailerId: str(STOP_RETAILER),
        retailerName: str(stopRetailer.name), address: str('Moyan, Kuching'),
        lat: dbl(stopRetailer.lat), lng: dbl(stopRetailer.lng), sequence: num(1),
        estimatedArrival: str('09:21'), estimatedDeparture: str('09:41'),
        priorityReason: str('E2E fixture'), status: str('not_started'),
        travelMinutesFromPrevious: num(21), legDistanceKm: dbl(8.4),
      })]),
    })]),
  });

  const out = E.outputDir();
  fs.writeFileSync(
    path.join(out, 'dev_accounts_e2e.json'),
    JSON.stringify({ DEV_ACCOUNTS: 'Salesperson|' + E.SALES_EMAIL + '|' + E.PASSWORD + '|salesman' }),
  );

  return { adminUid: uids.admin, salesUid: uids.salesman, routeId: ROUTE_ID, stopId: STOP_ID, retailerId: STOP_RETAILER };
}

module.exports = { seed, putPerson, ROUTE_ID, STOP_ID, STOP_RETAILER, PRODUCTS, RETAILERS };

if (require.main === module) {
  seed().then(
    (r) => console.log('seeded fixture: ' + JSON.stringify(r)),
    (e) => { console.error(e.message || e); process.exit(1); },
  );
}
