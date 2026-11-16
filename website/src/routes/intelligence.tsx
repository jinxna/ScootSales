import { createFileRoute } from '@tanstack/react-router'
import { SiteFooter, SiteHeader } from '../components/SiteChrome'
import { ClosingCTA, PageIntro, ProductShot, SectionHeading } from '../components/Marketing'

export const Route = createFileRoute('/intelligence')({
  component: IntelligencePage,
  head: () => ({
    meta: [
      { title: 'Intelligence — Scoot Sales' },
      {
        name: 'description',
        content: 'Understand read-only mobile Scout, retailer briefs, weekly demand forecasts and route comparisons that keep managers in control.',
      },
    ],
  }),
})

function IntelligencePage() {
  return (
    <>
      <SiteHeader />
      <main id="main" className="page">
        <PageIntro
          title="A clearer next decision"
          action={{ href: '#copilot', label: 'Explore Scout' }}
        >
          Turn recorded orders, visits and route progress into useful context.
          Ask a supported question, review a retailer brief or compare a route
          option. The team keeps control of what happens next.
        </PageIntro>

        <section id="copilot" className="section wrap" aria-labelledby="copilot-title">
          <div className="feature-row">
            <div className="feature-copy">
              <h2 id="copilot-title">Ask about your sales day</h2>
              <p>
                Mobile Scout recognises a defined set of questions and reads the
                signed-in salesperson’s own route, orders and available visit briefs.
                It can point you to the relevant screen without changing the record.
              </p>
              <ul className="bullet-list">
                <li>“What is my next stop?”</li>
                <li>“How many stops are left today?”</li>
                <li>“Show my orders this week.”</li>
                <li>“Show the visit brief for [retailer name].”</li>
              </ul>
              <p>
                Use a retailer’s name for the visit brief. Available answers depend
                on the assigned route, recorded progress and records the account can read.
              </p>
            </div>
            <div className="feature-media surface">
              <div className="reading">
                <h3>Illustrative conversation</h3>
                <p className="note">Illustrative conversation · sample data</p>
                <dl>
                  <dt>Salesperson</dt>
                  <dd>Show the visit brief for Sample Retailer.</dd>
                  <dt>Example response</dt>
                  <dd>
                    No current visit brief insights are available for Sample Retailer.
                  </dd>
                </dl>
                <p className="note">
                  Written example of a supported question and a missing-brief
                  response. This is not a live assistant or a recorded runtime result.
                </p>
              </div>
            </div>
          </div>
          <div className="faq-list">
            <details>
              <summary>How does mobile Scout interpret a question?</summary>
              <p>
                Deterministic rules map recognised English and selected Malay phrases
                to supported read-only actions. Answers use existing data services.
                Unsupported questions receive guidance to supported prompts.
                Scout does not generate free-text business decisions or write orders,
                visits or route progress.
              </p>
            </details>
          </div>
        </section>

        <section className="section surface" aria-labelledby="memory-title">
          <div className="wrap feature-row">
            <div className="feature-copy">
              <h2 id="memory-title">Remember the last visit</h2>
              <p>Retailer memory gives the next conversation a starting point. Review recorded outcomes and available context before deciding what to ask or follow up.</p>
              <p>A structured no-order outcome can explain why the visit did not become an order. Keep those recorded facts separate from a suggested next action.</p>
              <a className="text-link" href="/product#order-workflow">Connect the brief to the visit ↗</a>
            </div>
            <ProductShot src="/product/Visit-logs.png" alt="Visit Logs with recorded visit history and follow-up information" caption="Visit history provides recorded context · actual capture with simulation data" />
          </div>
        </section>

        <section className="section wrap" aria-labelledby="manager-title">
          <div className="feature-row reverse">
            <div className="feature-copy">
              <h2 id="manager-title">Brief first. Then investigate.</h2>
              <p>
                The manager briefing brings attention items into a short list.
                Ask “What needs my attention?” to review the briefing, then
                “Explain item 1” to examine the reason behind a listed item.
              </p>
              <p>
                Briefing and explanation are read-only requests. Review the underlying
                records before acting, especially when a source is unavailable or
                the briefing may be incomplete.
              </p>
              <p className="note">
                These prompts describe the dashboard Scout briefing and explanation
                flow. Availability depends on the account and dashboard view.
              </p>
            </div>
            <div className="feature-media">
              <ProductShot
                src="/product/dashboard.png"
                alt="Dashboard showing attention queues for route workflow, retailer coverage and commercial risk"
                caption="Attention queues provide context for manager review. This screenshot is not a Scout conversation; its records are simulated."
              />
            </div>
          </div>
        </section>

        <section id="forecasting" className="section wrap" aria-labelledby="forecast-title">
          <div className="feature-row">
            <div className="feature-copy">
              <h2 id="forecast-title">Plan for demand, with context</h2>
              <p>
                Weekly demand forecasts estimate how much may be ordered in a coming
                period. Read them alongside the available history and uncertainty
                before using them to prepare a visit or compare opportunities.
              </p>
              <p>
                The shared weekly forecasting core includes an adaptive approach
                that selects a method for the demand pattern, plus a separate SARIMA
                option for comparison when enough history is available.
              </p>
              <p>
                An insufficient-history result is useful information: it means there
                is not enough evidence for that forecast. A forecast range expresses
                uncertainty; it is not a promise about the next order.
              </p>
            </div>
            <div className="feature-media">
              <ProductShot
                src="/product/Prediction.png"
                alt="Demand forecast dashboard showing insufficient-history status"
                caption="The forecast view can show insufficient history instead of a forecast. Records shown are simulated demo data."
              />
            </div>
          </div>
          <div className="faq-list">
            <details>
              <summary>What is SARIMA, and when is it eligible?</summary>
              <p>
                SARIMA means Seasonal Autoregressive Integrated Moving Average.
                It models changes over time and a repeating seasonal pattern.
                The current weekly implementation requires 104 completed weeks
                and at least two positive observations in the series.
              </p>
              <p>
                Those thresholds permit an attempt; they do not establish accuracy.
                Insufficient history or a failed fit leaves the SARIMA forecast
                unavailable. It does not silently substitute an adaptive result.
              </p>
            </details>
            <details>
              <summary>What does the forecast estimate mean?</summary>
              <p>
                The central estimate is expected demand for the period, including
                periods with no orders. It is not the amount conditional on an order
                happening. Expected order value follows a shared calculation
                so planning views use the same meaning.
              </p>
              <p>
                Adaptive forecast ranges use past forecast errors. SARIMA ranges
                use model-based uncertainty. Neither guarantees that future demand
                will fall inside the displayed range.
              </p>
            </details>
          </div>
          <p className="note">
            SARIMA comparison is implemented. A reviewed evaluation is needed
            before making accuracy claims.
          </p>
        </section>

        <section id="route-comparison" className="section wrap" aria-labelledby="comparison-title">
          <div className="feature-row reverse">
            <div className="feature-copy">
              <h2 id="comparison-title">Compare before you commit</h2>
              <p>
                Different routes serve different priorities. Compare candidates for
                commercial opportunity, at-risk retailers or broader coverage before
                choosing a draft to review.
              </p>
              <p>
                Expected value and distance are estimates. They are not guaranteed
                revenue, travel time or outcomes. Review retailer context, location
                quality and practical constraints before approving a plan.
              </p>
              <a className="text-link" href="/product#routes">Follow the route handover</a>
            </div>
            <div className="feature-media">
              <ProductShot
                src="/product/route-priorities.png"
                alt="Route planner priorities view with ranked retailer candidates and route scenario comparisons"
                caption="Compare suggested route scenarios before manager approval and publication. All displayed planning records are simulated."
              />
            </div>
          </div>
          <div className="facts-grid">
            <article>
              <h3>Revenue balance</h3>
              <p>Consider estimated commercial opportunity alongside the proposed route’s travel demands.</p>
            </article>
            <article>
              <h3>Risk rescue</h3>
              <p>Give attention to retailers whose recorded signals suggest a need for follow-up.</p>
            </article>
            <article>
              <h3>Coverage</h3>
              <p>Consider retailers needing a visit, including those with limited commercial history.</p>
            </article>
          </div>
          <p className="note">
            Every option remains a suggestion. A manager must review, approve and
            publish the route before the salesperson works the assigned plan.
          </p>
        </section>

        <section className="section wrap">
          <SectionHeading title="Know the boundaries">
            Useful intelligence makes its limits clear.
          </SectionHeading>
          <div className="faq-list">
            <details>
              <summary>Can mobile Scout change my orders or route?</summary>
              <p>
                Mobile Scout is read-only. It answers supported questions about
                your own records and can open the relevant screen. It cannot submit
                an order, complete a stop or change a published route.
              </p>
            </details>
            <details>
              <summary>What if a brief or forecast is missing?</summary>
              <p>
                Review the available retailer records and use your judgement.
                Missing briefs, insufficient history and unavailable sources should
                remain visible limits. They are not evidence of zero demand or
                proof that no follow-up is needed.
              </p>
            </details>
            <details>
              <summary>Do suggestions publish a route automatically?</summary>
              <p>
                A suggestion can inform a draft. Manager review, approval and
                publication are required. Generated intelligence does not change
                published routes or recorded route progress.
              </p>
            </details>
            <details>
              <summary>Has SARIMA been shown to outperform other methods?</summary>
              <p>
                SARIMA comparison is implemented. A reviewed evaluation is needed
                before claiming that it is more accurate than another method.
                Demo records and screenshots do not establish forecasting
                performance or business returns.
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
