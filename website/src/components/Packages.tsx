import '../styles/sales.css'
import { allowanceRows, packages } from '../lib/packages'

export function Packages({ onChoose }: { onChoose: (name: string) => void }) {
  return (
    <section className="ss-section ss-packages ss-wrap" id="packages" aria-labelledby="packages-heading">
      <p className="ss-eyebrow">Packages</p>
      <h2 className="ss-title" id="packages-heading">Four template packages.</h2>
      <p className="ss-intro">Each package sets how many people of each role a company can have, and how many products it can hold in the catalogue.</p>

      <div className="ss-pkg-grid">
        {packages.map((pkg) => (
          <article className="ss-pkg-card" key={pkg.planId} aria-labelledby={'pkg-' + pkg.planId}>
            <header>
              <h3 id={'pkg-' + pkg.planId}>{pkg.name}</h3>
              <span className="ss-pkg-edition">{pkg.edition === 'advanced' ? 'Advanced edition' : 'Basic edition'}</span>
            </header>
            <dl className="ss-pkg-allowances">
              {allowanceRows.map((row) => (
                <div key={row.key}>
                  <dt>{row.label}</dt>
                  <dd>{pkg.limits[row.key].toLocaleString('en-US')}</dd>
                </div>
              ))}
            </dl>
            <p className="ss-pkg-price">{pkg.price}</p>
            <a className="ss-button ss-pkg-action" href="#contact" aria-label={'Contact sales about ' + pkg.name} onClick={() => onChoose(pkg.name)}>Contact sales</a>
          </article>
        ))}
      </div>

      <div className="ss-pkg-notes">
        <div>
          <h3>Basic and Advanced editions</h3>
          <p>{packages.filter((pkg) => pkg.edition === 'basic').map((pkg) => pkg.name).join(' and ')} use the Basic edition. Basic includes orders, purchase orders and special requests, products, categories and retailers, the weekly route planner and saved routes, salesman tracking and visit logs, retailer score sheets, reports, the phone app with offline ordering, and Scout for orders and routes. {packages.filter((pkg) => pkg.edition === 'advanced').map((pkg) => pkg.name).join(' and ')} use the Advanced edition. Advanced adds the demand forecast, the action centre, the weekly AI summary, the Trust and Impact Lab, route priorities and retailer segments, retailer memory and replenishment, and visit briefs on the phone and in Scout. Forecasts need enough sales history to say anything useful.</p>
        </div>
        <div>
          <h3>More seats than a package includes</h3>
          <p>Custom seat additions are arranged through sales. Tell us what you need in the inquiry form.</p>
        </div>
        <div>
          <h3>How payment works</h3>
          <p>There is no online card payment. A customer asks for a plan on the dashboard Plans page and the Scoot Sales team contacts them. The team records the payment and emails a receipt. This site has no card form, order basket or trial sign-up.</p>
        </div>
        <div>
          <h3>Template values</h3>
          <p>These are the current template allowances. They are a starting point for a conversation, not a final offer, and prices are shared when you contact sales.</p>
        </div>
      </div>
    </section>
  )
}
