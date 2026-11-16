import { createFileRoute } from '@tanstack/react-router'
import { SiteFooter, SiteHeader } from '../components/SiteChrome'
import { ClosingCTA, PageIntro, ProductShot, SectionHeading } from '../components/Marketing'

export const Route = createFileRoute('/product')({
  component: ProductPage,
  head: () => ({
    meta: [
      { title: 'Product — Scoot Sales' },
      {
        name: 'description',
        content: 'Connect retailer score sheets, mobile orders, visit records and manager-reviewed routes in one sales workflow.',
      },
    ],
  }),
})

function ProductPage() {
  return (
    <>
      <SiteHeader />
      <main id="main" className="page">
        <PageIntro
          title="A connected sales day"
          action={{ href: '#order-workflow', label: 'Follow an order' }}
        >
          Set up the products. Take the order at the retailer. Bring the visit record
          back into the next plan. Scoot Sales connects the field team and the people
          who support them.
        </PageIntro>

        <section className="section wrap" aria-labelledby="score-sheets-title">
          <div className="feature-row">
            <div className="feature-copy">
              <h2 id="score-sheets-title">Start with the right products</h2>
              <p>
                Maintain the product catalogue and build retailer score sheets around
                the items that belong in the visit. Give the salesperson a prepared
                product list instead of a blank order form.
              </p>
              <ul className="bullet-list">
                <li>Organise the catalogue for product selection.</li>
                <li>Choose the products included in a retailer score sheet.</li>
                <li>Review score-sheet settings before the field team uses them.</li>
              </ul>
            </div>
            <div className="feature-media">
              <ProductShot
                src="/product/score-sheet-builder.png"
                alt="Score sheet builder with a product list and retailer score-sheet setup"
                caption="Prepare a retailer score sheet from the catalogue. Records shown are simulated demo data."
                eager
              />
            </div>
          </div>
        </section>

        <section id="order-workflow" className="section wrap" aria-labelledby="order-title">
          <div className="feature-row reverse">
            <div className="feature-copy">
              <h2 id="order-title">From the aisle to an order</h2>
              <p>
                Begin a guided retailer visit, choose products and enter quantities.
                Review the order with the retailer and capture a signature before
                submitting it.
              </p>
              <p>
                If the connection drops, the order can remain queued on the device
                for synchronisation when connectivity returns. Check its sync status
                before treating it as received by the office.
              </p>
              <p className="note">
                Connection resilience covers queued orders. Other screens and fresh
                data reads can still need a connection.
              </p>
            </div>
            <div className="feature-media">
              <ProductShot
                src="/product/mobile-signed-order.png"
                className="mobile-capture"
                alt="Mobile order review screen with ordered products and signature capture"
                caption="Review and sign within the mobile order workflow. Demo records are simulated."
              />
            </div>
          </div>
          <ol className="flow-strip" aria-label="Mobile order workflow">
            <li>Start the visit</li>
            <li>Select products</li>
            <li>Review quantities</li>
            <li>Capture signature</li>
            <li>Submit and check sync</li>
          </ol>
        </section>

        <section className="section wrap" aria-labelledby="memory-title">
          <div className="feature-row">
            <div className="feature-copy">
              <h2 id="memory-title">Carry the context forward</h2>
              <p>
                Retailer memory brings recorded visit context into the next
                conversation. A visit brief helps the salesperson review available
                issues and follow-up points before starting the stop.
              </p>
              <p>
                Record structured outcomes after the conversation so the next visit
                starts with a useful account of what happened. A suggested follow-up
                still needs the salesperson’s judgement.
              </p>
              <a className="text-link" href="/intelligence#copilot">Explore visit briefs and Scout</a>
            </div>
            <div className="feature-media">
              <ProductShot
                src="/product/mobile-guided-visit.png"
                className="mobile-capture"
                alt="Guided retailer visit screen with visit stages and an order workspace"
                caption="The guided visit keeps the retailer stop and its order workspace together. Simulated demo records."
              />
            </div>
          </div>
        </section>

        <section id="routes" className="section wrap" aria-labelledby="routes-title">
          <div className="feature-row reverse">
            <div className="feature-copy">
              <h2 id="routes-title">A plan with a clear handover</h2>
              <p>
                Managers prepare a route draft, review it for approval and publish
                the assigned plan. The salesperson reads that published route and
                records progress against its stops.
              </p>
              <p>
                Route and stop progress return to the dashboard for review.
                Suggestions can inform the next draft; they do not silently change
                a published route or the salesperson’s recorded progress.
              </p>
              <a className="text-link" href="/intelligence#route-comparison">See how route options compare</a>
            </div>
            <div className="feature-media">
              <ProductShot
                src="/product/route-planner.png"
                alt="Weekly route planner showing assigned stops and the Kuching map"
                caption="Prepare and review a route before publishing it to the salesperson. Simulated planning data."
              />
            </div>
          </div>
          <ol className="flow-strip" aria-label="Assigned route lifecycle">
            <li>Draft</li>
            <li>Approve</li>
            <li>Publish</li>
            <li>Work the assigned route</li>
            <li>Record progress</li>
            <li>Review on the dashboard</li>
          </ol>
        </section>

        <section className="section wrap" aria-labelledby="attention-title">
          <div className="feature-row">
            <div className="feature-copy">
              <h2 id="attention-title">Know what needs attention</h2>
              <p>
                The Exception Control Tower gathers route workflow, coverage,
                commercial-risk and data-blocker follow-ups into role-scoped queues.
                Open the relevant record to understand the issue before deciding
                what to do.
              </p>
              <p>
                Visit logs and recorded outcomes give that review context. Managers
                can distinguish planned work from recorded activity without treating
                a suggestion as a completed action.
              </p>
            </div>
            <div className="feature-media">
              <ProductShot
                src="/product/dashboard.png"
                alt="Management dashboard with Exception Control Tower queues for route workflow, coverage and data blockers"
                caption="Review exceptions within the signed-in user’s scope. Dashboard records shown are simulated."
              />
            </div>
          </div>
        </section>

        <section id="management" className="section wrap" aria-labelledby="reports-title">
          <div className="feature-row reverse">
            <div className="feature-copy">
              <h2 id="reports-title">A shared record, useful views</h2>
              <p>
                Review orders, visit activity and operational reports from the
                dashboard. Access follows the signed-in person’s role and assigned
                scope, so each team works with the records it is authorised to see.
              </p>
              <p>
                Use reports to examine recorded activity and guide follow-up.
                They describe the available records; they do not establish sales
                gains or productivity improvements.
              </p>
            </div>
            <div className="feature-media">
              <ProductShot
                src="/product/Reports.png"
                alt="Reports dashboard showing operational summaries and report controls"
                caption="Operational reports from the product interface. Figures shown come from simulated demo records."
              />
            </div>
          </div>
          <div className="facts-grid">
            <article>
              <h3>Administrator</h3>
              <p>Manage access, catalogue records and assignments within authorised scope.</p>
            </article>
            <article>
              <h3>Supervisor</h3>
              <p>Review assigned salespeople’s orders, visits and follow-up work.</p>
            </article>
            <article>
              <h3>Branch manager</h3>
              <p>Review branch activity, route planning, retailer coverage and reports.</p>
            </article>
          </div>
        </section>

        <section className="section wrap">
          <SectionHeading title="Before you get started">
            A few practical boundaries of the sales workflow.
          </SectionHeading>
          <div className="faq-list">
            <details>
              <summary>Can the whole app work without a connection?</summary>
              <p>
                Queued orders provide resilience during connection drops. The app
                still needs connectivity for other operations and fresh reads.
                Review the order’s sync status after reconnecting.
              </p>
            </details>
            <details>
              <summary>Can a suggestion change an assigned route?</summary>
              <p>
                Suggestions inform planning. A manager must review, approve and
                publish the route. The mobile app records assigned-route progress
                separately from the published plan.
              </p>
            </details>
            <details>
              <summary>Does everyone see the same dashboard data?</summary>
              <p>
                Available records depend on the person’s role and assigned scope.
                Supervisor and branch views provide the relevant team or branch context.
              </p>
            </details>
            <details>
              <summary>Are the screenshots from a customer rollout?</summary>
              <p>
                These are genuine product screens showing simulated demo records.
                They illustrate workflows and do not demonstrate production usage
                or measured business results.
              </p>
            </details>
          </div>
        </section>
        <ClosingCTA />
      </main>
      <SiteFooter />
    </>
  )
}
