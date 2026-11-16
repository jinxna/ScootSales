import '../styles/sales.css'
type Shot =
  | { kind: 'desktop'; src: string; alt: string; caption: string }
  | { kind: 'phone'; src: string; alt: string; caption: string }
  | { kind: 'placeholder'; label: string; alt: string }

type Chapter = {
  id: string
  step: string
  where: string
  title: string
  lead: string
  points: { title: string; body: string }[]
  shots: Shot[]
}

const chapters: Chapter[] = [
  {
    id: 'plan-week',
    step: '1',
    where: 'Office',
    title: 'Plan the week’s routes',
    lead: 'Before the week starts, the office decides which retailers each salesperson visits and in what order.',
    points: [
      { title: 'See the week', body: 'The Weekly Route Planner shows the stops, the workload and a map of the retailers.' },
      { title: 'Compare options', body: 'Ranked retailer priorities and route scenarios give a manager a starting selection. They are suggestions, not instructions.' },
      { title: 'Approve and publish', body: 'A manager reviews and approves the route. Once it is published, the salesperson sees the stops on the phone.' },
    ],
    shots: [
      { kind: 'desktop', src: '/product/route-planner.png', alt: 'Weekly Route Planner showing stops, workload and the Kuching map', caption: 'Weekly Route Planner' },
      { kind: 'desktop', src: '/product/route-priorities.png', alt: 'Weekly Route Planner priorities view showing ranked candidate retailers and the route scenario comparison panel', caption: 'Priorities and route scenarios' },
    ],
  },
  {
    id: 'visit-retailer',
    step: '2',
    where: 'Field',
    title: 'Visit the retailer',
    lead: 'On the phone, the salesperson accepts the published route, starts it and opens the next stop.',
    points: [
      { title: 'Follow the route', body: 'Accept the route, start it, then pick a stop from the list.' },
      { title: 'Mark arrival', body: 'Arrival is marked on the stop. If the person has turned on location sharing, the app adds a location fix as supporting evidence. Sharing is optional.' },
      { title: 'Work through the visit', body: 'The guided visit moves through the stages of the stop, so the order starts from the visit and not from a blank screen.' },
    ],
    shots: [
      { kind: 'phone', src: '/product/mobile-guided-visit.png', alt: 'Guided visit screen in the salesperson app, showing the visit stages and order workspace', caption: 'Guided visit' },
    ],
  },
  {
    id: 'take-order',
    step: '3',
    where: 'Field',
    title: 'Check the products and take the order',
    lead: 'The order is built on the phone from the product list set up for that retailer.',
    points: [
      { title: 'Retailer score sheets', body: 'Each retailer has a score sheet: a focused list chosen from the master catalogue, with retailer-specific visibility and packing settings. The salesperson sees the products that matter for that shop.' },
      { title: 'Search, scan or pick', body: 'Search the list, browse by category and enter quantities. Barcode scanning is an optional shortcut. Products without barcodes are chosen by hand and can still be ordered.' },
      { title: 'Review and sign', body: 'The order is reviewed on screen, the retailer signs, and the salesperson submits it.' },
      { title: 'Drafts on the phone', body: 'An order in progress can be saved as a draft on the phone. A draft is submitted only when the salesperson chooses to submit it.' },
    ],
    shots: [
      { kind: 'phone', src: '/product/mobile-product-selection.png', alt: 'Mobile product selection screen with search, categories and add-to-cart actions', caption: 'Choose products' },
      { kind: 'phone', src: '/product/mobile-signed-order.png', alt: 'Order review screen with quantities, signature and submission actions', caption: 'Review and sign' },
      { kind: 'desktop', src: '/product/score-sheet-builder.png', alt: 'Score Sheet Builder with the retailer list, selected product count, visibility toggles and packing size for each product', caption: 'Retailer score sheet (office view)' },
      { kind: 'placeholder', label: 'Barcode scanner', alt: 'Placeholder for the barcode scanner screen of the salesperson app. No screenshot has been captured yet.' },
      { kind: 'placeholder', label: 'Saved draft', alt: 'Placeholder for the saved draft screen of the salesperson app. No screenshot has been captured yet.' },
    ],
  },
  {
    id: 'office-processing',
    step: '4',
    where: 'Office',
    title: 'Approve and follow up in the office',
    lead: 'Submitted orders reach the management dashboard as the record the salesperson sent, without being typed again.',
    points: [
      { title: 'Approval', body: 'The All Orders page lists submitted orders. Authorised office staff approve or reject each one.' },
      { title: 'Order history', body: 'Filter orders by status, salesperson, retailer or date, and look back through earlier orders.' },
      { title: 'Team activity', body: 'Visit logs and team activity show which stops were visited and what needs follow-up. Live location appears only for people who have turned sharing on.' },
      { title: 'CSV export', body: 'Export the filtered order list, the visit logs or the product list as CSV for use in a spreadsheet.' },
    ],
    shots: [
      { kind: 'desktop', src: '/product/all-orders.png', alt: 'All Orders dashboard showing filters and submitted order records', caption: 'All Orders' },
      { kind: 'desktop', src: '/product/Salesman-tracking.png', alt: 'Salesperson tracking view showing field activity and retailer coverage', caption: 'Team activity' },
      { kind: 'desktop', src: '/product/Visit-logs.png', alt: 'Visit Logs dashboard showing recent field visits and follow-up records', caption: 'Visit logs' },
    ],
  },
]

function ShotView({ shot }: { shot: Shot }) {
  if (shot.kind === 'placeholder') {
    return (
      <figure className="ss-story-shot ss-story-placeholder" role="img" aria-label={shot.alt}>
        <div className="ss-story-placeholder-frame" aria-hidden="true">
          <b>{shot.label}</b>
          <span>Screenshot to be added</span>
        </div>
      </figure>
    )
  }
  if (shot.kind === 'phone') {
    return (
      <figure className="ss-story-shot ss-story-phone">
        <div className="ss-phone-shell"><div className="ss-phone-screen"><img src={shot.src} alt={shot.alt} loading="lazy" /></div></div>
        <figcaption>{shot.caption}</figcaption>
      </figure>
    )
  }
  return (
    <figure className="ss-story-shot ss-story-desktop">
      <div className="ss-frame"><img src={shot.src} alt={shot.alt} loading="lazy" /></div>
      <figcaption>{shot.caption}</figcaption>
    </figure>
  )
}

export function HowItWorks() {
  return (
    <section className="ss-section ss-how ss-wrap" id="how-it-works" aria-labelledby="how-heading">
      <p className="ss-eyebrow">What Scoot Sales does</p>
      <h2 className="ss-title" id="how-heading">A week of field sales, from plan to processed order.</h2>
      <p className="ss-intro">Scoot Sales has two parts: a phone app for salespeople and a management dashboard for the office. Follow one week through both.</p>

      <ol className="ss-how-list">
        {chapters.map((chapter) => (
          <li className="ss-how-chapter" id={chapter.id} key={chapter.id}>
            <div className="ss-how-text">
              <p className="ss-how-step"><span aria-hidden="true">{chapter.step}</span>{chapter.where}</p>
              <h3>{chapter.title}</h3>
              <p className="ss-how-lead">{chapter.lead}</p>
              <dl className="ss-how-points">
                {chapter.points.map((point) => (
                  <div key={point.title}>
                    <dt>{point.title}</dt>
                    <dd>{point.body}</dd>
                  </div>
                ))}
              </dl>
            </div>
            <div className={'ss-how-media ss-how-media-' + chapter.id}>
              {chapter.shots.map((shot) => (
                <ShotView shot={shot} key={shot.kind === 'placeholder' ? shot.label : shot.src} />
              ))}
            </div>
          </li>
        ))}
      </ol>

      <p className="ss-note">Every screen shown is a real capture from the apps, except the boxes marked &ldquo;Screenshot to be added&rdquo;. Records visible in the captures are team-entered simulation and testing data.</p>
    </section>
  )
}
