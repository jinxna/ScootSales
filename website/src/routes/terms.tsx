import { createFileRoute } from '@tanstack/react-router'
import { LegalPage } from '../components/LegalPage'

export const Route = createFileRoute('/terms')({
  component: () => <LegalPage kind="terms" />,
  head: () => ({
    meta: [
      { title: 'Terms of Use - Scoot Sales' },
      {
        name: 'description',
        content: 'Terms for authorised use of the Scoot Sales application.',
      },
    ],
  }),
})
