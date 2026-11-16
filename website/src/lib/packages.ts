import generated from './packages.json'

export type PackageAllowances = {
  salesmen: number
  supervisors: number
  admins: number
  branchManagers: number
  products: number
}

export type PackageTemplate = {
  planId: string
  name: string
  edition: 'basic' | 'advanced'
  limits: PackageAllowances
  price: string
}

export const packages = generated as PackageTemplate[]

export const allowanceRows: { key: keyof PackageAllowances; label: string }[] = [
  { key: 'salesmen', label: 'Salespeople' },
  { key: 'supervisors', label: 'Supervisors' },
  { key: 'admins', label: 'Administrators' },
  { key: 'branchManagers', label: 'Branch managers' },
  { key: 'products', label: 'Products in the catalogue' },
]
