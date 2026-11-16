import { contactEmail } from '../lib/inquiry'

const links = [
  { href: '/product', label: 'Product' },
  { href: '/intelligence', label: 'Intelligence' },
  { href: '/#how-it-works', label: 'How it works' },
  { href: '/#roles', label: 'For your team' },
  { href: '/#packages', label: 'Packages' },
  { href: '/#faq', label: 'FAQ' },
  { href: '/context', label: 'Our story' },
]

export function SiteHeader() {
  return (
    <header className="site-header">
      <div className="topbar wrap">
        <a className="brand" href="/" aria-label="Scoot Sales home"><span className="brand-mark" aria-hidden="true" />Scoot Sales</a>
        <nav className="desktop-nav" aria-label="Main navigation">{links.map(link => <a key={link.href} href={link.href}>{link.label}</a>)}</nav>
        <a className="button nav-action" href="/#contact">Contact sales <span aria-hidden="true">↗</span></a>
        <details className="mobile-menu"><summary>Menu <span aria-hidden="true">＋</span></summary><nav aria-label="Mobile navigation">{links.map(link => <a key={link.href} href={link.href}>{link.label}</a>)}<a href="/#contact">Contact sales ↗</a></nav></details>
      </div>
    </header>
  )
}

export function SiteFooter() {
  return (
    <footer className="site-footer">
      <div className="footer-content wrap">
        <div className="footer-brand"><a className="brand" href="/"><span className="brand-mark" aria-hidden="true" />Scoot Sales</a><p>From a retailer visit<br />to a clearer next decision.</p><span>Kuching, Sarawak · FMCG field sales</span></div>
        <nav aria-label="Product footer navigation"><h2>Explore</h2><a href="/product">The connected sales day</a><a href="/intelligence">Scout & intelligence</a><a href="/#routes">Route planning</a><a href="/#roles">Views for your team</a><a href="/#packages">Packages</a><a href="/#faq">FAQ</a><a href="/#contact">Contact sales</a></nav>
        <nav aria-label="Project footer navigation"><h2>The project</h2><a href="/context">Why we built it</a><a href="/context#evidence">Evidence & current scope</a><a href="/privacy">Privacy notice</a><a href="/terms">Evaluation terms</a><a href="/delete-account">Delete your account</a></nav>
      </div>
      <div className="footer-bottom wrap"><span>Scoot Sales · Sales & intelligence, connected.</span><span>Contact, support and security: <a href={'mailto:' + contactEmail}>{contactEmail}</a></span><span>Product captures use simulation and testing data.</span></div>
    </footer>
  )
}
