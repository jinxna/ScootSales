'use strict';

const E = require('./emulator.cjs');

const BRANCH = { id: 'B1', name: 'E2E Kuching Branch' };

const ACCOUNTS = {
  admin: { email: 'e2e.admin@example.test', name: 'E2E Admin', role: 'admin', code: 'ADM-E2E', branch: BRANCH.id },
  supervisor: { email: 'e2e.supervisor@example.test', name: 'E2E Supervisor', role: 'supervisor', code: 'SUP-E2E', branch: BRANCH.id },
  salesman: { email: 'e2e.sales1@example.test', name: 'E2E Salesperson', role: 'salesman', code: 'S001', branch: BRANCH.id },
  branchManager: { email: 'e2e.bm@example.test', name: 'E2E Branch Manager', role: 'branch_manager', code: 'BM-E2E', branch: BRANCH.id },
};

const PRODUCTS = [
  { id: 'prod-1', name: 'ORGANIC APPLE CIDER VINEGAR (12BTL X 946ML)', barcode: '9555592203502', code: 'R001-BEV-001', dept: 'GROCERY', price: 28.12 },
  { id: 'prod-2', name: 'INSTANT BABY OAT (24P X 450G)', barcode: '9555592202598', code: 'R002-ORG-002', dept: 'BABY PRODUCTS', price: 9.01 },
  { id: 'prod-3', name: 'REGULAR ROLLED OAT (24P X 450G)', barcode: '9555592202611', code: 'R003-ORG-003', dept: 'GROCERY', price: 9.01 },
];

const RETAILERS = [
  { id: 'ret-1', name: 'Choice Supermarket Tabuan Jaya', area: 'Tabuan', lat: 1.5312, lng: 110.3609 },
  { id: 'ret-2', name: 'Emart Moyan', area: 'Moyan', lat: 1.5535, lng: 110.3593 },
];

const SEAT_CLASS = { salesman: 'salesman', supervisor: 'supervisor', admin: 'manager', branch_manager: 'manager', developer: 'none' };

async function putPerson(db, person, extra = {}) {
  const { uid } = await db.ensureUser(person.email, person.name);
  const isSales = person.role === 'salesman';
  await db.put('users', person.email, {
    uid, userUid: uid, name: person.name, email: person.email,
    role: person.role, user_group: person.role, status: 'active',
    seatClass: SEAT_CLASS[person.role] || 'none', seatHeld: person.role !== 'developer',
    employeeCode: person.code, userId: person.code,
    branchId: person.branch, branch_id: person.branch,
    contactNumber: '0123456789',
    ...(isSales ? { gpsAutofill: false, supervisorId: extra.supervisorCode || '', supervisor_id: extra.supervisorCode || '' } : {}),
    ...(person.role === 'supervisor' ? { assignedSalesmanCodes: extra.assignedSalesmanCodes || [] } : {}),
  });
  await db.put('user_access', uid, {
    accessVersion: 2, uid, userDocId: person.email, employeeCode: person.code,
    userId: person.code, email: person.email, role: person.role, user_group: person.role,
    status: 'active', isActive: true, branchId: person.branch, branch_id: person.branch,
    supervisorId: isSales ? extra.supervisorCode || '' : '', supervisor_id: isSales ? extra.supervisorCode || '' : '',
    supervisorUid: isSales ? extra.supervisorUid || '' : '',
    seatClass: SEAT_CLASS[person.role] || 'none', seatHeld: person.role !== 'developer',
    ...(person.role === 'supervisor' ? { assignedSalesmanCodes: extra.assignedSalesmanCodes || [] } : {}),
    updatedAt: new Date(),
  });
  return uid;
}

async function seedBase(db) {
  const uids = {};
  uids.admin = await putPerson(db, ACCOUNTS.admin);
  uids.supervisor = await putPerson(db, ACCOUNTS.supervisor, { assignedSalesmanCodes: [ACCOUNTS.salesman.code] });
  uids.salesman = await putPerson(db, ACCOUNTS.salesman, { supervisorUid: uids.supervisor, supervisorCode: ACCOUNTS.supervisor.code });
  uids.branchManager = await putPerson(db, ACCOUNTS.branchManager);

  await db.put('branches', BRANCH.id, {
    branchId: BRANCH.id, name: BRANCH.name, branchName: BRANCH.name, status: 'active',
  });

  for (const p of PRODUCTS) {
    await db.put('products', p.id, {
      productId: p.id, itemCode: p.code, productCode: p.code,
      itemName: p.name, productName: p.name, barcode: p.barcode, itemBarcode: p.barcode,
      packagingSpecification: '24 X 500ML', unitPrice: p.price,
      brandName: 'TENTEN', brand: 'TENTEN',
      departmentName: p.dept, mainCategoryName: p.dept,
      sortOrder: 0, isVisible: true,
    });
  }

  for (const r of RETAILERS) {
    await db.put('retailers', r.id, {
      retailerId: r.id, retailerName: r.name, name: r.name, area: r.area,
      branchId: BRANCH.id, status: 'active', address: `${r.area}, Kuching`,
      latitude: r.lat, longitude: r.lng,
      coordinateStatus: 'verified', coordinateReviewStatus: 'reviewed', coordinateSource: 'admin_review',
      assignedSalesmanId: ACCOUNTS.salesman.code, assignedSalesmanCode: ACCOUNTS.salesman.code,
      assignedSalesmanUid: uids.salesman,
    });
    await db.put('retailer_score_sheet_settings', r.id, {
      retailerId: r.id, retailerName: r.name,
      visibleProductIds: PRODUCTS.map((p) => p.id), hiddenProductIds: [], disabledProductIds: [],
      productCount: PRODUCTS.length, visibleProductCount: PRODUCTS.length,
      sheetName: `${r.name} Score Sheet`,
    });
  }
  return { uids, branch: BRANCH };
}

const FULL_SUPERVISOR = { email: 'e2e.supervisor2@example.test', name: 'E2E Full Supervisor', role: 'supervisor', code: 'SUP2-E2E', branch: BRANCH.id };
async function seedFullSupervisor(db) {
  const codes = ['S101', 'S102', 'S103', 'S104', 'S105'];
  const uid = await putPerson(db, FULL_SUPERVISOR, { assignedSalesmanCodes: codes });
  for (const code of codes) {
    await putPerson(db, {
      email: `e2e.sales${code.slice(1)}@example.test`, name: `E2E Team Member ${code}`,
      role: 'salesman', code, branch: BRANCH.id,
    }, { supervisorUid: uid, supervisorCode: FULL_SUPERVISOR.code });
  }
  return { supervisor: FULL_SUPERVISOR, uid, codes };
}

module.exports = { ACCOUNTS, BRANCH, PRODUCTS, RETAILERS, FULL_SUPERVISOR, putPerson, seedBase, seedFullSupervisor };
