import { existsSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = dirname(dirname(fileURLToPath(import.meta.url)))
const catalogueFile = join(root, '..', 'platform_service', 'plan_catalogue.json')
const jsonFile = join(root, 'src', 'lib', 'packages.json')
const pageFile = join(root, 'site-static', 'index.html')
const check = process.argv.includes('--check')

const ROWS = [
  ['salesmen', 'Salespeople'],
  ['supervisors', 'Supervisors'],
  ['admins', 'Administrators'],
  ['branchManagers', 'Branch managers'],
  ['products', 'Products in the catalogue'],
]
const DEFAULT_PRICE = 'Contact sales for pricing'

const catalogue = JSON.parse(readFileSync(catalogueFile, 'utf8'))
const plans = catalogue.plans
  .filter((plan) => plan.visibility === 'public')
  .sort((a, b) => a.sortOrder - b.sortOrder)
  .map((plan) => ({
    planId: plan.planId,
    name: plan.name,
    edition: plan.edition,
    limits: Object.fromEntries(ROWS.map(([key]) => [key, plan.limits[key]])),
    price: plan.notes || DEFAULT_PRICE,
  }))
if (plans.length !== 4) throw new Error('expected four public plans, found ' + plans.length)
const priced = catalogue.plans.filter((plan) => plan.visibility === 'public' && (plan.prices.monthly !== null || plan.prices.yearly !== null))
if (priced.length) throw new Error(priced.map((plan) => plan.planId).join(', ') + ' carries prices in the catalogue; review whether they are approved before showing them')

const basic = plans.filter((plan) => plan.edition === 'basic').map((plan) => plan.name)
const advanced = plans.filter((plan) => plan.edition === 'advanced').map((plan) => plan.name)
const join2 = (names) => names.join(' and ')

const card = (plan) =>
  '<article class="ss-pkg-card" aria-labelledby="pkg-' + plan.planId + '"><header><h3 id="pkg-' + plan.planId + '">' + plan.name +
  '</h3><span class="ss-pkg-edition">' + (plan.edition === 'advanced' ? 'Advanced edition' : 'Basic edition') + '</span></header>' +
  '<dl class="ss-pkg-allowances">' +
  ROWS.map(([key, label]) => '<div><dt>' + label + '</dt><dd>' + plan.limits[key].toLocaleString('en-US') + '</dd></div>').join('') +
  '</dl><p class="ss-pkg-price">' + plan.price + '</p><a class="ss-button ss-pkg-action" href="#contact" aria-label="Contact sales about ' +
  plan.name + '">Contact sales</a></article>'

const json = JSON.stringify(plans, null, 2) + '\n'
const hasPage = existsSync(pageFile)
let page = hasPage ? readFileSync(pageFile, 'utf8') : ''
const gridStart = page.indexOf('<div class="ss-pkg-grid">')
const gridEnd = page.indexOf('</div><div class="ss-pkg-notes">')
if (hasPage && (gridStart < 0 || gridEnd < gridStart)) throw new Error('packages grid not found in site-static/index.html')
if (hasPage) page = page.slice(0, gridStart) + '<div class="ss-pkg-grid">' + plans.map(card).join('') + page.slice(gridEnd)
if (hasPage) page = page.replace(
  /<p>[^<]*use the Basic edition[^<]*<\/p>/,
  '<p>' + join2(basic) + ' use the Basic edition, which has no demand forecast or AI assistant views. ' + join2(advanced) +
    ' use the Advanced edition, which adds them. Forecasts need enough sales history to say anything useful.</p>',
)
if (hasPage) page = page.replace(
  /(<option[^>]*>Not sure yet<\/option>)(?:<option>[^<]*<\/option>)+/,
  '$1' + plans.map((plan) => '<option>' + plan.name + '</option>').join(''),
)

if (check) {
  const same = readFileSync(jsonFile, 'utf8') === json && (!hasPage || readFileSync(pageFile, 'utf8') === page)
  if (!same) {
    console.error('Packages differ from platform_service/plan_catalogue.json. Run npm run generate:packages.')
    process.exit(1)
  }
  console.log('packages match platform_service/plan_catalogue.json for ' + plans.map((plan) => plan.planId).join(', '))
} else {
  writeFileSync(jsonFile, json)
  if (hasPage) writeFileSync(pageFile, page)
  console.log('wrote packages for ' + plans.map((plan) => plan.planId).join(', '))
}
