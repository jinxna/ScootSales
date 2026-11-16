'use strict';

const BRANCH = { id: 'HW1', name: 'Hardware Branch' };
const PASSWORDS = {
  A0001: 'Hw-Admin-Old-0001!',
  SV0001: 'Hw-Super-Old-0001!',
  S0001: 'Hw-Sales-Old-0001!',
  S0002: 'Hw-Sales-Old-0002!',
  U0001: 'Hw-Extra-Old-0001!',
  P0001: 'Hw-Extra-Old-0002!',
  G0001: 'Hw-Extra-Old-0003!',
  I0001: 'Hw-Extra-Old-0004!',
  N0001: 'Hw-Extra-Old-0005!',
  W0001: 'Hw-Extra-Old-0006!',
  R0001: 'Hw-Extra-Old-0007!',
  M0001: 'Hw-Extra-Old-0008!',
  X0001: 'Hw-Extra-Old-0009!',
};

const CORE = [
  { key: 'admin', code: 'A0001', role: 'admin', email: 'hw.admin@example.test', name: 'Hardware Admin' },
  { key: 'sup', code: 'SV0001', role: 'supervisor', email: 'hw.sup@example.test', name: 'Hardware Supervisor' },
  { key: 's1', code: 'S0001', role: 'salesman', email: 'hw.s1@example.test', name: 'Hardware Sales One' },
  { key: 's2', code: 'S0002', role: 'salesman', email: 'hw.s2@example.test', name: 'Hardware Sales Two' },
];

const SHAPE_PEOPLE = {
  uidProfileOnly: { key: 'uidProfileOnly', code: 'U0001', role: 'salesman', email: 'hw.uid.only@example.test', name: 'Hardware Uid Profile Only' },
  profileWithoutUid: { key: 'profileWithoutUid', code: 'P0001', role: 'salesman', email: 'hw.no.uid@example.test', name: 'Hardware Profile Without Uid' },
  userGroupRole: { key: 'userGroupRole', code: 'G0001', role: 'salesman', email: 'hw.group@example.test', name: 'Hardware User Group Role' },
  inactive: { key: 'inactive', code: 'I0001', role: 'salesman', email: 'hw.inactive@example.test', name: 'Hardware Inactive' },
  noLink: { key: 'noLink', code: 'N0001', role: 'salesman', email: 'hw.nolink@example.test', name: 'Hardware No Link' },
  unknownRole: { key: 'unknownRole', code: 'R0001', role: 'forklift', email: 'hw.role@example.test', name: 'Hardware Unknown Role' },
  profileMissing: { key: 'profileMissing', code: 'M0001', role: 'salesman', email: 'hw.noprofile@example.test', name: 'Hardware Missing Profile' },
  noAuthAccount: { key: 'noAuthAccount', code: 'X0001', role: 'salesman', email: 'hw.noaccount@example.test', name: 'Hardware No Auth Account', withoutAccount: true },
  swappedRow: { key: 'swappedRow', code: 'W0001', role: 'salesman', email: 'hw.swapped@example.test', name: 'Hardware Swapped Row', rowId: 'swapped-profile-doc' },
};

const PRODUCTS = [
  { id: 'HW-0001', name: 'Wood screw 2in', category: 'Fasteners', unit: 'box', price: 12.5, visible: true },
  { id: 'HW-0002', name: 'Claw hammer 16oz', category: 'Hand tools', unit: 'pcs', price: 28.9, visible: true },
  { id: 'HW-0003', name: 'PVC pipe 20mm', category: 'Plumbing', unit: 'pcs', price: 7.2, visible: true },
  { id: 'HW-0004', name: 'Hidden cable tie', category: 'Electrical', unit: 'pack', price: 3.1, visible: false },
];

const RETAILER = { id: 'hw-ret-1', name: 'Kuching Hardware Supplies' };

async function createAuthAccount(authEmulator, person) {
  const url = authEmulator.project
    ? `${authEmulator.authBase}/projects/${authEmulator.project}/accounts`
    : `${authEmulator.authBase}/accounts:signUp?key=fake-api-key`;
  const response = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Connection: 'close', ...(authEmulator.project ? { Authorization: 'Bearer owner' } : {}) },
    body: JSON.stringify({ email: person.email, password: PASSWORDS[person.code], displayName: person.name, returnSecureToken: true }),
  });
  const body = await response.json();
  if (!response.ok) throw new Error(`auth sign-up ${person.email} -> ${JSON.stringify(body)}`);
  return body.localId;
}

function identityFields(person) {
  const isSales = person.role === 'salesman';
  return {
    userId: person.code,
    employeeCode: person.code,
    email: person.email,
    role: person.role,
    user_group: person.role,
    status: 'active',
    isActive: true,
    branchId: BRANCH.id,
    branch_id: BRANCH.id,
    supervisorId: isSales ? 'SV0001' : '',
    supervisor_id: isSales ? 'SV0001' : '',
  };
}

function profileOf(person, uid, extra = {}) {
  return {
    uid,
    ...identityFields(person),
    name: person.name,
    username: person.email.split('@')[0],
    contactNumber: '0123456789',
    contact_number: '0123456789',
    ...extra,
  };
}

function legacyAccessOf(person, uid, extra = {}) {
  return { uid, userDocId: person.code, ...identityFields(person), ...extra };
}

function accessV2Of(person, uid, supervisorUid) {
  const isSales = person.role === 'salesman';
  return {
    ...legacyAccessOf(person, uid),
    accessVersion: 2,
    supervisorUid: isSales ? supervisorUid : '',
    seatClass: isSales ? 'salesperson' : 'free',
    ...(person.role === 'supervisor' ? { assignedSalesmanCodes: ['S0001', 'S0002'] } : {}),
    updatedAt: new Date(),
  };
}

async function seedLegacyCompany(projectClient, authEmulator, { shapes = [] } = {}) {
  const unknown = shapes.filter((shape) => !SHAPE_PEOPLE[shape]);
  if (unknown.length) throw new Error(`unknown legacy shapes: ${unknown.join(', ')}`);
  await projectClient.reset();
  const people = {};
  for (const person of [...CORE, ...shapes.map((shape) => SHAPE_PEOPLE[shape])]) {
    const uid = person.withoutAccount ? `no-account-${person.code.toLowerCase()}` : await createAuthAccount(authEmulator, person);
    people[person.key] = { ...person, password: PASSWORDS[person.code], uid };
  }
  const uids = Object.fromEntries(Object.entries(people).map(([key, person]) => [key, person.uid]));

  await projectClient.put('branches', BRANCH.id, { branchId: BRANCH.id, name: BRANCH.name, branchName: BRANCH.name, status: 'active' });

  for (const person of CORE) {
    const { uid } = people[person.key];
    await projectClient.put('users', person.code, profileOf(person, uid, person.role === 'supervisor' ? { assignedSalesmanCodes: ['S0001', 'S0002'] } : {}));
    const access = person.key === 's2' ? legacyAccessOf(person, uid) : accessV2Of(person, uid, uids.sup);
    await projectClient.put('user_access', uid, access);
  }

  if (people.uidProfileOnly) {
    const person = people.uidProfileOnly;
    await projectClient.put('users', person.uid, profileOf(person, person.uid));
  }
  if (people.profileWithoutUid) {
    const person = people.profileWithoutUid;
    const { uid: omitted, ...profile } = profileOf(person, person.uid);
    await projectClient.put('users', person.code, profile);
    await projectClient.put('user_access', person.uid, legacyAccessOf(person, person.uid));
  }
  if (people.userGroupRole) {
    const person = people.userGroupRole;
    const { role: omitted, ...profile } = profileOf(person, person.uid, { user_group: 'Sales Representative' });
    await projectClient.put('users', person.code, profile);
    const { role: omittedAccessRole, ...access } = legacyAccessOf(person, person.uid, { user_group: 'Sales Representative' });
    await projectClient.put('user_access', person.uid, access);
  }
  if (people.inactive) {
    const person = people.inactive;
    const inactive = { status: 'inactive', isActive: false };
    await projectClient.put('users', person.code, profileOf(person, person.uid, inactive));
    await projectClient.put('user_access', person.uid, legacyAccessOf(person, person.uid, inactive));
  }
  if (people.swappedRow) {
    const person = people.swappedRow;
    await projectClient.put('users', person.rowId, profileOf(person, person.uid));
    await projectClient.put('user_access', person.rowId, { ...legacyAccessOf(person, person.uid), userDocId: person.uid });
  }
  if (people.unknownRole) {
    const person = people.unknownRole;
    await projectClient.put('users', person.code, profileOf(person, person.uid));
    await projectClient.put('user_access', person.uid, legacyAccessOf(person, person.uid));
  }
  if (people.profileMissing) {
    const person = people.profileMissing;
    await projectClient.put('user_access', person.uid, legacyAccessOf(person, person.uid));
  }
  if (people.noAuthAccount) {
    const person = people.noAuthAccount;
    await projectClient.put('users', person.code, profileOf(person, person.uid));
    await projectClient.put('user_access', person.uid, legacyAccessOf(person, person.uid));
  }
  if (people.noLink) {
    const person = people.noLink;
    const { userDocId: omitted, ...access } = legacyAccessOf(person, person.uid);
    await projectClient.put('user_access', person.uid, access);
  }

  let order = 0;
  for (const product of PRODUCTS) {
    order += 1;
    await projectClient.put('products', product.id, {
      productId: product.id,
      departmentName: 'Hardware',
      mainCategoryName: product.category,
      categoryName: product.category,
      itemName: product.name,
      itemCode: product.id,
      sku: product.id,
      uom: product.unit,
      uomLabel: product.unit,
      unitOfMeasure: product.unit,
      unitPrice: product.price,
      price: product.price,
      priceGuide: product.price,
      sortOrder: order,
      brandName: '',
      isVisible: product.visible,
      status: 'active',
    });
  }

  await projectClient.put('retailers', RETAILER.id, {
    retailerId: RETAILER.id,
    retailerName: RETAILER.name,
    name: RETAILER.name,
    area: 'Kuching',
    branchId: BRANCH.id,
    status: 'active',
    address: 'Kuching',
    latitude: 1.55,
    longitude: 110.35,
    coordinateStatus: 'needs_review',
    assignedSalesmanId: 'S0001',
    assignedSalesmanCode: 'S0001',
    assignedSalesmanUid: uids.s1,
  });

  return { people, uids, branch: BRANCH, products: PRODUCTS, retailer: RETAILER, passwords: PASSWORDS };
}

module.exports = { seedLegacyCompany, BRANCH, PRODUCTS, PASSWORDS, SHAPE_PEOPLE };
