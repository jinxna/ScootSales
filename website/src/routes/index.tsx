import { createFileRoute } from '@tanstack/react-router'
import { useState } from 'react'
import { Faq } from '../components/Faq'
import { HowItWorks } from '../components/HowItWorks'
import { InquiryForm } from '../components/InquiryForm'
import { Packages } from '../components/Packages'
import { UseCases } from '../components/UseCases'
import { SiteFooter, SiteHeader } from '../components/SiteChrome'
import { ChoiceGroup, ClosingCTA, ProductShot, SectionHeading } from '../components/Marketing'

export const Route = createFileRoute('/')({
  component: HomePage,
  head: () => ({ meta: [
    { title: 'Scoot Sales — Field sales, better informed' },
    { name: 'description', content: 'Connect FMCG retailer visits, orders, Scout, route planning and weekly demand intelligence in one sales workflow.' },
  ] }),
})

const day = [
  { label: 'Plan', question: 'Which retailers need a visit?', title: 'Give the day a direction', body: 'Compare retailer priorities and route scenarios. A manager reviews, approves and publishes the plan before the salesperson starts.', handoff: 'The published route becomes the salesperson’s assigned work.', src: 'route-priorities.png', alt: 'Weekly Route Planner with retailer priorities and revenue versus risk scenarios' },
  { label: 'Brief', question: 'What should I know before I go?', title: 'Bring the last visit with you', body: 'Use the retailer brief to review recorded context, recent outcomes and follow-up suggestions. Scout helps open the information you need.', handoff: 'Retailer memory informs the conversation; suggestions stay separate from recorded facts.', src: 'Visit-logs.png', alt: 'Visit Logs with recorded visits and follow-up evidence', caption: 'Visit history capture · retailer-brief explanation is a walkthrough illustration' },
  { label: 'Visit', question: 'What do I need at this stop?', title: 'Keep the visit together', body: 'Open the assigned retailer and work through preparation, selling and closing in the mobile guided visit.', handoff: 'The visit connects the assigned stop to its order or structured outcome.', src: 'mobile-guided-visit.png', alt: 'Mobile guided visit with preparation, selling and closing stages', mobile: true },
  { label: 'Order', question: 'Can I capture it here?', title: 'From quantities to sign-off', body: 'Find products, enter quantities and collect a signature. Order work is preserved through connection drops, with sync status visible when connectivity returns.', handoff: 'Authorised office teams review the shared order record.', src: 'mobile-signed-order.png', alt: 'Mobile order review with products, quantities and signature', mobile: true },
  { label: 'Follow up', question: 'What needs attention next?', title: 'Make the outcome useful', body: 'Orders, stop progress and structured visit outcomes return to management. Exceptions and follow-ups feed the next planning cycle.', handoff: 'The next decision starts with evidence from the field.', src: 'dashboard.png', alt: 'Management dashboard showing Exception Control Tower and follow-up queues' },
]

const copilot = [
  { label: 'Next stop', question: 'Where should I go next?', response: 'Open the next stop on your assigned route, with the retailer and visit context together.', note: 'Uses the route already assigned to the salesperson.' },
  { label: 'Visit brief', question: 'Visit brief for Demo Retailer', response: 'Open the retailer brief to review recorded context, recent outcomes and suggested follow-up before the conversation.', note: 'Demo Retailer is an illustrative name, not a client record.' },
  { label: 'My orders', question: 'My orders this week', response: 'Review your own orders for the current week, without searching through unrelated team records.', note: 'Mobile commands stay within the authenticated salesperson’s scope.' },
]

const roles = [
  { label: 'Salesperson', title: 'Stay with the visit', body: 'Your route, retailer context, catalogue and order workspace stay close at hand. Capture the outcome while it is fresh.', src: 'mobile-guided-visit.png', alt: 'Salesperson mobile guided visit', mobile: true, caption: 'Salesperson app' },
  { label: 'Administrator', title: 'Keep the system organised', body: 'Manage users, catalogue records, retailers and assignments through the administrator console.', src: 'admin.png', alt: 'Administrator console showing all-branch navigation and records', caption: 'Administrator console' },
  { label: 'Supervisor', title: 'See where to follow up', body: 'Review assigned team activity, visits, orders and incomplete work from the supervisor’s view.', src: 'supervisor.png', alt: 'Supervisor console showing team orders, visit logs and action centre', caption: 'Supervisor console' },
  { label: 'Branch manager', title: 'See the branch picture', body: 'Bring retailer coverage, route plans, orders and emerging demand signals into the branch-level conversation.', src: 'branchmanager.png', alt: 'Branch manager console showing branch overview, routes and reports', caption: 'Branch manager console' },
]

function HomePage() {
  const [preferredPackage, setPreferredPackage] = useState('Not sure yet')
  return (
    <>
      <SiteHeader />
      <main id="main">
        <section className="home-hero wrap">
          <div className="hero-masthead">
            <div className="masthead-message"><p>From the retailer<br /> to the next decision.</p><span>Built around the field-to-office journey.</span></div>
            <figure className="masthead-product"><img src="/product/route-planner.png" alt="Scoot Sales route planner with the Kuching map and planned retailer stops" fetchPriority="high" /><figcaption>Actual product capture · simulation data</figcaption></figure>
          </div>
          <div className="hero-editorial">
            <p className="hero-margin">For FMCG distribution teams.<br /> From Kuching, Sarawak.</p>
            <div><h1 className="hero-title">Field sales,<br />better informed.</h1><p className="hero-description">Connect retailer visits, orders, route planning and sales intelligence in one workflow for FMCG distribution teams.</p><div className="actions"><a className="button" href="#how-it-works">See how it works <span aria-hidden="true">↘</span></a><a className="text-link" href="#contact">Contact sales ↗</a><a className="text-link" href="/product">Explore the product ↗</a></div></div>
          </div>
        </section>

        <HowItWorks />

        <section className="section before-after" id="story"><div className="wrap">
          <SectionHeading title="One entry. A shared record."><p>The order used to travel by hand. Now the field visit and the office work from connected records.</p></SectionHeading>
          <div className="comparison"><div><h3>The paper handover</h3><p>Write the order. Carry it back. Type it again. Chase the missing detail.</p><span>Information arrives after the salesperson does.</span></div><div><h3>The connected workflow</h3><p>Capture at the retailer. Preserve the order. Sync when connected. Review and follow up.</p><span>The record connects the visit to the next decision.</span></div></div>
        </div></section>

        <section className="section wrap" id="walkthrough">
          <SectionHeading title="Follow a sales day"><p>Choose a moment in the journey. See what the salesperson and manager each bring to the same workflow.</p></SectionHeading>
          <ChoiceGroup id="workday" label="Choose a stage of the sales day" className="workday" entries={day.map(stage => ({ label: stage.label, content: <div className="walkthrough-scene"><div className="walkthrough-copy"><p className="scene-question">{stage.question}</p><h3>{stage.title}</h3><p>{stage.body}</p><p className="handoff">{stage.handoff}</p><a className="text-link" href="/product">See the full workflow ↗</a></div><ProductShot src={'/product/' + stage.src} alt={stage.alt} className={stage.mobile ? 'mobile-capture' : ''} caption={stage.caption || 'Actual product capture · simulation data'} /></div> }))} />
          <p className="note">A guided product walkthrough using existing captures. It does not connect to a live client workspace.</p>
        </section>

        <section className="section copilot-section" id="copilot"><div className="wrap">
          <SectionHeading title="Ask your next question"><p>Scout brings supported questions to the work in front of you. Find a next stop, open a retailer brief or review your own orders.</p></SectionHeading>
          <div className="copilot-layout"><div className="copilot-context"><span className="copilot-symbol" aria-hidden="true">↗</span><h3>Less searching.<br />More context.</h3><p>Purpose-built assistance for field sales, with defined commands and role-scoped access.</p><a className="text-link" href="/intelligence#copilot">Inside Scout ↗</a></div>
            <div className="copilot-demo" data-ui="illustrative-copilot"><p className="demo-label">Illustrative conversation · sample data</p><ChoiceGroup id="copilot-example" label="Choose a supported Scout question" entries={copilot.map(example => ({ label: example.label, content: <div className="conversation"><p className="question">{example.question}</p><div className="answer"><span className="assistant-name">Scoot Sales Scout</span><p>{example.response}</p></div><p className="note">{example.note}</p></div> }))} /><p className="copilot-boundary">Mobile Scout is read-only. It does not submit orders, approve routes or change another person’s records.</p></div>
          </div>
        </div></section>

        <section className="section wrap" id="routes">
          <SectionHeading title="Plan with a purpose"><p>The best next visit depends on the goal. Compare commercial opportunity, retailer risk and coverage before choosing a route.</p></SectionHeading>
          <div className="route-story"><ProductShot src="/product/route-priorities.png" alt="Route Scenario Studio comparing revenue balance and risk rescue with expected value, travel and workload" caption="Route Scenario Studio · actual capture with simulation data" /><div className="strategy-list"><article><h3>Revenue balance</h3><p>Weigh expected order value alongside retailer priority and open signals.</p></article><article><h3>Risk rescue</h3><p>Bring at-risk or dormant retailers into the planning conversation.</p></article><article><h3>Coverage</h3><p>Give overlooked and long-uncovered retailers a place in the plan.</p></article></div></div>
          <div className="route-lifecycle"><p>A suggestion becomes field work through a manager’s decision.</p><ol className="flow-strip"><li>Draft</li><li>Approve</li><li>Publish</li><li>Visit</li><li>Review progress</li></ol></div>
          <p className="note">Travel, service time and expected value are planning estimates. Suggestions never silently change a published route.</p>
        </section>

        <section className="section forecast-section" id="forecasting"><div className="wrap feature-row"><div className="feature-copy"><h2>Prepare for demand</h2><p className="lead">Turn order history into weekly demand estimates, with the uncertainty kept in view.</p><p>Adaptive forecasting handles different demand patterns. A separate SARIMA option explores seasonal history when enough completed weeks are available.</p><ul className="bullet-list"><li>Expected demand per week</li><li>Visible uncertainty and history limits</li><li>Insufficient-history states instead of invented certainty</li></ul><a className="text-link" href="/intelligence#forecasting">Forecasting & SARIMA explained ↗</a></div><div><ProductShot src="/product/Prediction.png" alt="Demand forecast dashboard showing products with insufficient order history" caption="Existing forecast capture · insufficient-history example" /><p className="note">SARIMA implementation is present; evaluation evidence still needs review. No accuracy improvement is claimed.</p></div></div></section>

        <section className="section wrap" id="roles">
          <SectionHeading title="A view for every role"><p>Connected records, with a workspace that reflects each person’s responsibilities.</p></SectionHeading>
          <ChoiceGroup id="team-role" label="Choose a team role" entries={roles.map(role => ({ label: role.label, content: <div className="role-scene"><div className="feature-copy"><h3>{role.title}</h3><p>{role.body}</p><a className="text-link" href="/product#management">Explore team workflows ↗</a></div><ProductShot src={'/product/' + role.src} alt={role.alt} caption={role.caption + ' · simulation data'} className={role.mobile ? 'mobile-capture' : ''} /></div> }))} />
        </section>

        <section className="section evidence-section" id="position"><div className="wrap">
          <SectionHeading title="What you can explore"><p>A working project with a clear scope. Product demonstrations and measured business results are different kinds of evidence.</p></SectionHeading>
          <div className="evidence-list"><div className="evidence-row"><h3>Connected operations</h3><p>Catalogue, retailer score sheets, guided visits, order capture, route workflows and management views.</p><span>Product captures available</span></div><div className="evidence-row"><h3>Sales intelligence</h3><p>Scout, retailer context, priorities, route scenarios and weekly forecasting.</p><span>Capabilities explained</span></div><div className="evidence-row"><h3>Evaluation</h3><p>Captures use simulation data. Productivity gains, sales uplift and SARIMA superiority are not established by this showcase.</p><a className="text-link" href="/context#evidence">Read the evidence notes ↗</a></div></div>
        </div></section>

        <UseCases />

        <Packages onChoose={setPreferredPackage} />

        <Faq />

        <InquiryForm packageName={preferredPackage} onPackageChange={setPreferredPackage} />
        <ClosingCTA />
      </main>
      <SiteFooter />
    </>
  )
}
