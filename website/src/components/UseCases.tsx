import '../styles/sales.css'
const uses = [
  { title: 'Hardware', body: 'Sales visits to building-supply and hardware shops, with an order taken at each stop. The project already includes a hardware variant that is used in testing.' },
  { title: 'Food distribution', body: 'Regular rounds to shops and food outlets: a weekly route, a visit at each stop and an order the office can approve.' },
  { title: 'Pharmaceutical sales', body: 'Representatives visiting pharmacies and clinics to record visits and take orders. Requirements specific to regulated stock would need to be assessed before this is considered.' },
  { title: 'Retail stock checks', body: 'A visit used to check what is on the shelf and note what is needed. The visit flow already includes a counting step.' },
]

export function UseCases() {
  return (
    <section className="ss-section ss-uses ss-wrap" id="uses" aria-labelledby="uses-heading">
      <p className="ss-eyebrow">Beyond the first brief</p>
      <h2 className="ss-title" id="uses-heading">Where else it could be used.</h2>
      <p className="ss-intro">Scoot Sales is built and tested around FMCG retail visits. The same pattern of weekly route, retailer visit and order may suit other field-sales work. These are possible uses to discuss, not tested deployments.</p>
      <ul className="ss-uses-grid">
        {uses.map((use) => (
          <li key={use.title}>
            <h3>{use.title}</h3>
            <p>{use.body}</p>
            <span className="ss-uses-tag">Possible use</span>
          </li>
        ))}
      </ul>
    </section>
  )
}
