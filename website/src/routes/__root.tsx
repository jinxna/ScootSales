import type { ReactNode } from 'react'
import { useEffect } from 'react'
import { initMarketing } from '../lib/marketing.js'
import {
  HeadContent,
  Outlet,
  Scripts,
  createRootRoute,
} from '@tanstack/react-router'
import appCss from '../styles/app.css?url'

export const Route = createRootRoute({
  head: () => ({
    meta: [
      { charSet: 'utf-8' },
      { name: 'viewport', content: 'width=device-width, initial-scale=1' },
      { title: 'Scoot Sales — Connected FMCG Field Sales' },
      {
        name: 'description',
        content:
          'Scoot Sales is a sales intelligence system connecting FMCG field visits, orders, operations and guided next steps.',
      },
      { property: 'og:title', content: 'Scoot Sales' },
      {
        property: 'og:description',
        content: 'Connect FMCG visits, orders, Scout, route planning and weekly demand intelligence.',
      },
      { property: 'og:type', content: 'website' },
      { name: 'twitter:card', content: 'summary_large_image' },
      { name: 'twitter:title', content: 'Scoot Sales' },
      {
        name: 'twitter:description',
        content: 'Connect FMCG visits, orders, Scout, route planning and weekly demand intelligence.',
      },
    ],
    links: [
      { rel: 'stylesheet', href: appCss },
      { rel: 'icon', href: '/icon.svg', type: 'image/svg+xml' },
    ],
  }),
  component: RootComponent,
  notFoundComponent: () => (
    <main className="not-found" id="main">
      <title>Page not found — Scoot Sales</title>
      <meta name="description" content="This Scoot Sales page is unavailable. Return to the project story." />
      <h1>Page not found</h1>
      <p>Let’s get you back to the product story.</p>
      <a className="button" href="/">Return to Scoot Sales ↗</a>
    </main>
  ),
})

function RootComponent() {
  useEffect(() => initMarketing(document), [])
  return (
    <RootDocument>
      <Outlet />
    </RootDocument>
  )
}

function RootDocument({ children }: Readonly<{ children: ReactNode }>) {
  return (
    <html lang="en">
      <head>
        <HeadContent />
      </head>
      <body>
        <a className="skip-link" href="#main">Skip to content</a>
        {children}
        <Scripts />
      </body>
    </html>
  )
}
