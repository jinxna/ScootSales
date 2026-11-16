export const contactEmailPlaceholder = 'REPLACE-CONTACT-EMAIL@example.invalid'
const configuredContactEmail = (import.meta.env.VITE_CONTACT_EMAIL as string | undefined)?.trim() ?? ''
export const contactEmailIsPlaceholder: boolean = configuredContactEmail === ''
export const contactEmail: string = configuredContactEmail || contactEmailPlaceholder

export const domainOptions = [
  'FMCG or supermarket supply',
  'Hardware',
  'Food distribution',
  'Pharmaceutical sales',
  'Retail stock checks',
  'Other',
]

export type InquiryValues = {
  company: string
  contact: string
  email: string
  phone: string
  packageName: string
  domain: string
  message: string
}

export type InquiryErrors = Partial<Record<'company' | 'contact' | 'email' | 'phone', string>>

export const emptyInquiry: InquiryValues = {
  company: '',
  contact: '',
  email: '',
  phone: '',
  packageName: 'Not sure yet',
  domain: domainOptions[0],
  message: '',
}

const emailPattern = /^[^\s@]+@[^\s@]+\.[^\s@]+$/
const phonePattern = /^[0-9+()\-.\s]{6,24}$/

export function validateInquiry(values: InquiryValues): InquiryErrors {
  const errors: InquiryErrors = {}
  if (!values.company.trim()) errors.company = 'Enter the company name.'
  if (!values.contact.trim()) errors.contact = 'Enter a contact name.'
  if (!values.email.trim()) errors.email = 'Enter an email address.'
  else if (!emailPattern.test(values.email.trim())) errors.email = 'Enter an email address such as name@company.com.'
  if (values.phone.trim() && !phonePattern.test(values.phone.trim())) errors.phone = 'Use digits, spaces, + and - only, or leave this blank.'
  return errors
}

const oneLine = (value: string) => value.replace(/\s+/g, ' ').trim()

export function buildInquiryText(values: InquiryValues): string {
  return [
    'Company: ' + oneLine(values.company),
    'Contact name: ' + oneLine(values.contact),
    'Email: ' + oneLine(values.email),
    'Phone: ' + (oneLine(values.phone) || 'Not given'),
    'Preferred package: ' + values.packageName,
    'Preferred domain: ' + values.domain,
    '',
    'Message:',
    values.message.trim() || 'No message.',
  ].join('\r\n')
}

export function buildInquiryMailto(values: InquiryValues): string {
  const subject = 'Scoot Sales inquiry: ' + oneLine(values.company) + ' (' + values.packageName + ')'
  return 'mailto:' + encodeURIComponent(contactEmail).replace(/%40/g, '@') + '?subject=' + encodeURIComponent(subject) + '&body=' + encodeURIComponent(buildInquiryText(values))
}
