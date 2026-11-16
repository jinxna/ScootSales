import { createFileRoute } from '@tanstack/react-router'
import { SiteFooter, SiteHeader } from '../components/SiteChrome'
import { ClosingCTA, PageIntro, ProductShot, SectionHeading } from '../components/Marketing'

export const Route = createFileRoute('/context')({
  component: ContextPage,
  head: () => ({ meta: [
    { title: 'Our story & evidence — Scoot Sales' },
    { name: 'description', content: 'Why Scoot Sales connects FMCG field visits and office work, with the project’s current scope and evaluation boundaries.' },
  ] }),
})

function ContextPage() {
  return <>
    <SiteHeader />
    <main id="main">
      <PageIntro title="Closer to the field" action={{ href: '/#walkthrough', label: 'Follow a sales day' }}><p>Scoot Sales began with a practical problem: an order taken at a retailer still had a long journey to the office.</p></PageIntro>
      <figure className="context-map wrap"><div className="context-mosaic"><img src="/product/kuching-contrast.png" alt="Map of Kuching, Sarawak, the geographical context for the project" /><img className="context-visit" src="/product/mobile-guided-visit.png" alt="The guided retailer visit where field records are captured, shown with simulation data" /></div><figcaption>Kuching, Sarawak · Map data © <a href="https://www.openstreetmap.org/copyright">OpenStreetMap contributors</a> · Rendered with terrarik.app · App capture uses simulation data</figcaption></figure>
      <section className="section wrap">
        <SectionHeading title="From paper to shared records"><p>Handwritten orders created work on both sides of the handover. The goal is to capture the record where the work happens.</p></SectionHeading>
        <div className="context-grid"><div><h3>The original handover</h3><ol className="process-list">{['Travel to the retailer', 'Check stock', 'Write the order', 'Collect a signature', 'Return to the office', 'Hand over the paperwork', 'Type the order again', 'Wait for an update'].map(step => <li key={step}>{step}</li>)}</ol></div><div><h3>The operational cost</h3><p>Salespeople spent time writing and checking. Office teams re-entered the record. Missing details required another conversation.</p><p>Managers saw the result after the paperwork arrived, rather than through a connected view of visits, orders and follow-ups.</p><h3>What changes</h3><p>One field record can support order review, route progress, retailer context and the next management decision.</p><a className="text-link" href="/product">See the connected workflow ↗</a></div></div>
      </section>
      <section className="section surface"><div className="wrap">
        <SectionHeading title="Built around the next visit"><p>Digitising the order is the starting point. The larger value is connecting the recorded outcome to what the team does next.</p></SectionHeading>
        <div className="feature-row"><div className="feature-copy"><h3>Keep the context</h3><p>Retailer memory and structured visit outcomes give the next conversation a starting point. Scout helps salespeople open relevant information.</p><h3>Bring it into planning</h3><p>Demand estimates, retailer priorities and route scenarios support the manager’s review. The approved plan then returns to the field.</p></div><ProductShot src="/product/Visit-logs.png" alt="Visit Logs showing recent visits and follow-up information" caption="Actual product capture · simulation and testing records" /></div>
      </div></section>
      <section className="section wrap" id="evidence">
        <SectionHeading title="What the evidence says"><p>The project’s scope is broader than its measured results. Here is how to read the demonstrations responsibly.</p></SectionHeading>
        <div className="evidence-notes">
          <article><h3>Demonstration data</h3><p>Captures use team-entered simulation and testing records, associated in some cases with real Kuching retailer entities. They are not a complete client production dataset or retailer endorsements.</p></article>
          <article><h3>The time-saving target</h3><p>The proposed approximately 30% reduction in salesperson working time is an objective for controlled user testing. It is not a measured outcome.</p></article>
          <article><h3>Forecast evaluation</h3><p>The weekly forecasting core and a separate SARIMA option are implemented. This website does not establish SARIMA accuracy or superiority. Adequate history and a reviewed evaluation are needed.</p></article>
          <article><h3>Human review</h3><p>Intelligence supports decisions. Managers approve and publish route plans. Location evidence is supplementary and depends on the user enabling location sharing.</p></article>
        </div>
      </section>
      <section className="section surface"><div className="wrap feature-row"><ProductShot src="/product/score-sheet-builder.png" alt="Retailer score-sheet builder with product selection and retailer context" caption="Retailer score-sheet builder · actual product capture" /><div className="feature-copy"><h2>Designed to be evaluated</h2><p>Client and stakeholder review should ask whether the connected workflow helps a salesperson complete a visit and helps a manager decide what to do next.</p><p>That means testing the task, the handover and the follow-up, alongside order quality, usability and time spent.</p><a className="text-link" href="/intelligence">Explore the intelligence layer ↗</a></div></div></section>
      <ClosingCTA />
    </main>
    <SiteFooter />
  </>
}
