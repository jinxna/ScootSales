import type { ReactNode } from 'react'

export function ProductShot({ src, alt, caption, className = '', eager = false }: { src: string; alt: string; caption: string; className?: string; eager?: boolean }) {
  return (
    <figure className={`product-shot ${className}`}>
      <a href={src} target="_blank" rel="noopener noreferrer" aria-label={`Open full capture: ${alt} (new tab)`}>
        <div className="shot-viewport"><img src={src} alt={alt} loading={eager ? 'eager' : 'lazy'} decoding="async" /></div>
      </a>
      <figcaption><span>{caption}</span><a href={src} target="_blank" rel="noopener noreferrer" aria-label={`Enlarge ${alt} (new tab)`}>Enlarge ↗</a></figcaption>
    </figure>
  )
}

export function PageIntro({ title, children, action }: { title: string; children: ReactNode; action?: { href: string; label: string } }) {
  return <section className="page-intro wrap"><h1>{title}</h1><div><div className="lead">{children}</div>{action && <a className="text-link" href={action.href}>{action.label} <span aria-hidden="true">↗</span></a>}</div></section>
}

export function SectionHeading({ title, children }: { title: string; children?: ReactNode }) {
  return <div className="section-heading"><h2>{title}</h2>{children && <div className="lead">{children}</div>}</div>
}

export function ClosingCTA() {
  return <section className="closing-cta"><div className="wrap"><h2>See how it all connects</h2><div><p>The field visit, the office view, and the intelligence behind the next decision. Explore the complete product story.</p><div className="actions"><a className="button light" href="/product">Explore the product <span aria-hidden="true">↗</span></a><a className="text-link" href="/intelligence">Explore intelligence ↗</a></div></div></div></section>
}

export function ChoiceGroup({ id, label, entries, className = '' }: { id: string; label: string; className?: string; entries: { label: string; content: ReactNode }[] }) {
  return (
    <div className={`choice-group ${className}`} data-choice-group={id}>
      <div className="choice-tabs" data-choice-tabs aria-label={label} hidden>
        {entries.map((entry, i) => <button key={entry.label} type="button" id={`${id}-tab-${i}`} aria-controls={`${id}-panel-${i}`}>{entry.label}</button>)}
      </div>
      {entries.map((entry, i) => <div key={entry.label} className="choice-panel" id={`${id}-panel-${i}`} data-choice-panel>{entry.content}</div>)}
    </div>
  )
}
