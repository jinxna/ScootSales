import { contactEmail, contactEmailIsPlaceholder } from '../lib/inquiry'
import { SiteFooter, SiteHeader } from './SiteChrome'

const steps = [
  'Open the Scoot Sales app and sign in.',
  'Go to Profile and choose Delete account.',
  'Enter your password and choose Request deletion.',
  'You are signed out. Your sign-in is turned off.',
  'Your company administrator can delete your account sooner or cancel the request. If they do nothing, your account is deleted after 30 days.',
]

export function DeleteAccountPage() {
  return (
    <>
      <SiteHeader />
      <main className="page" id="main">
        <section className="legal-page wrap" aria-labelledby="legal-title">
          <h1 id="legal-title">Delete your account</h1>
          <p className="legal-intro">How to ask for your Scoot Sales account and personal data to be deleted.</p>
          <div className="legal-sections">
            <section className="legal-section">
              <h2>Steps in the app</h2>
              <ol>{steps.map((step) => <li key={step}>{step}</li>)}</ol>
            </section>
            <section className="legal-section">
              <h2>What is deleted</h2>
              <p>Your sign-in, name, email address, phone number, profile photo and location history.</p>
            </section>
            <section className="legal-section">
              <h2>What your company keeps</h2>
              <p>Orders, visits and signatures are company records, so they stay. Your name on them becomes "Deleted user".</p>
            </section>
            <section className="legal-section">
              <h2>If you cannot use the app</h2>
              <p>
                Write to <a href={'mailto:' + contactEmail}>{contactEmail}</a> from the email address on your account. Support passes your request to your company administrator.
                {contactEmailIsPlaceholder ? ' This support address is a placeholder and must be replaced before launch.' : ''}
              </p>
            </section>
          </div>
        </section>
      </main>
      <SiteFooter />
    </>
  )
}
