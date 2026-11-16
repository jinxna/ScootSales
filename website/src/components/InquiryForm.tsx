import '../styles/sales.css'
import { useRef, useState, type ChangeEvent, type FormEvent } from 'react'
import { packages } from '../lib/packages'
import {
  buildInquiryMailto,
  buildInquiryText,
  contactEmail,
  contactEmailIsPlaceholder,
  domainOptions,
  emptyInquiry,
  validateInquiry,
  type InquiryErrors,
  type InquiryValues,
} from '../lib/inquiry'

type Props = {
  packageName: string
  onPackageChange: (name: string) => void
}

type Status = { tone: 'idle' | 'error' | 'info'; text: string }

const packageChoices = ['Not sure yet', ...packages.map((pkg) => pkg.name)]

export function InquiryForm({ packageName, onPackageChange }: Props) {
  const [values, setValues] = useState<InquiryValues>(emptyInquiry)
  const [errors, setErrors] = useState<InquiryErrors>({})
  const [status, setStatus] = useState<Status>({ tone: 'idle', text: '' })
  const formRef = useRef<HTMLFormElement>(null)
  const current: InquiryValues = { ...values, packageName }

  function update(event: ChangeEvent<HTMLInputElement | HTMLSelectElement | HTMLTextAreaElement>) {
    const { name, value } = event.target
    if (name === 'packageName') onPackageChange(value)
    else setValues((previous) => ({ ...previous, [name]: value }))
    if (name in errors) setErrors((previous) => ({ ...previous, [name]: undefined }))
    if (status.tone !== 'idle') setStatus({ tone: 'idle', text: '' })
  }

  function validated(): boolean {
    const found = validateInquiry(current)
    setErrors(found)
    const first = Object.keys(found)[0]
    if (first) {
      setStatus({ tone: 'error', text: 'Check the highlighted fields. No email draft was opened.' })
      formRef.current?.querySelector<HTMLElement>('[name="' + first + '"]')?.focus()
      return false
    }
    return true
  }

  function onSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (!validated()) return
    window.location.href = buildInquiryMailto(current)
    setStatus({
      tone: 'info',
      text: 'An email draft should now be open in your mail app. Nothing has been sent until you send it from there. If no draft opened, use Copy message and email it yourself.',
    })
  }

  async function copyMessage() {
    if (!validated()) return
    try {
      await navigator.clipboard.writeText(buildInquiryText(current))
      setStatus({ tone: 'info', text: 'The message was copied. It has not been sent anywhere.' })
    } catch {
      setStatus({ tone: 'error', text: 'Copying was blocked by the browser. Use Open email draft instead.' })
    }
  }

  const fieldError = (name: keyof InquiryErrors) =>
    errors[name] ? <span className="ss-field-error" id={'err-' + name}>{errors[name]}</span> : null
  const described = (name: keyof InquiryErrors) => (errors[name] ? 'err-' + name : undefined)

  return (
    <section className="ss-section ss-inquiry ss-wrap" id="contact" aria-labelledby="contact-heading">
      <div className="ss-inquiry-intro">
        <p className="ss-eyebrow">Contact sales</p>
        <h2 className="ss-title" id="contact-heading">Tell us about your team.</h2>
        <p className="ss-intro">Pick a package, or say you are not sure, and describe how your salespeople work today. The Scoot Sales team replies about set-up, pricing and seats.</p>
        <p className="ss-inquiry-honesty">This form prepares an email in your own mail app. This site does not receive or store what you type, and a message is only sent when you send it from your mail app.{contactEmailIsPlaceholder ? ' The Scoot Sales contact address has not been set for this build. The draft opens addressed to the placeholder ' + contactEmail + ', which must be replaced before launch.' : ''}</p>
      </div>

      <form className="ss-inquiry-form" ref={formRef} onSubmit={onSubmit} noValidate>
        <div className="ss-field">
          <label htmlFor="company">Company name</label>
          <input id="company" name="company" type="text" autoComplete="organization" required aria-invalid={Boolean(errors.company)} aria-describedby={described('company')} value={values.company} onChange={update} />
          {fieldError('company')}
        </div>
        <div className="ss-field">
          <label htmlFor="contact-name">Contact name</label>
          <input id="contact-name" name="contact" type="text" autoComplete="name" required aria-invalid={Boolean(errors.contact)} aria-describedby={described('contact')} value={values.contact} onChange={update} />
          {fieldError('contact')}
        </div>
        <div className="ss-field">
          <label htmlFor="email">Email</label>
          <input id="email" name="email" type="email" autoComplete="email" required aria-invalid={Boolean(errors.email)} aria-describedby={described('email')} value={values.email} onChange={update} />
          {fieldError('email')}
        </div>
        <div className="ss-field">
          <label htmlFor="phone">Phone <small>(optional)</small></label>
          <input id="phone" name="phone" type="tel" autoComplete="tel" aria-invalid={Boolean(errors.phone)} aria-describedby={described('phone')} value={values.phone} onChange={update} />
          {fieldError('phone')}
        </div>
        <div className="ss-field">
          <label htmlFor="packageName">Preferred package</label>
          <select id="packageName" name="packageName" value={packageName} onChange={update}>
            {packageChoices.map((choice) => <option key={choice}>{choice}</option>)}
          </select>
        </div>
        <div className="ss-field">
          <label htmlFor="domain">Preferred domain</label>
          <select id="domain" name="domain" value={values.domain} onChange={update}>
            {domainOptions.map((choice) => <option key={choice}>{choice}</option>)}
          </select>
        </div>
        <div className="ss-field ss-field-wide">
          <label htmlFor="message">Message <small>(optional)</small></label>
          <textarea id="message" name="message" rows={5} value={values.message} onChange={update} />
        </div>

        <div className="ss-inquiry-actions ss-field-wide">
          <button className="ss-form-button" type="submit">Open email draft</button>
          <button className="ss-form-button ss-form-button-quiet" type="button" onClick={copyMessage}>Copy message</button>
        </div>
        <p className={'ss-form-status ss-form-status-' + status.tone} role="status" aria-live="polite">{status.text}</p>
        {contactEmail ? <p className="ss-inquiry-direct ss-field-wide">You can also write to <a href={'mailto:' + contactEmail}>{contactEmail}</a>.</p> : null}
      </form>
    </section>
  )
}
