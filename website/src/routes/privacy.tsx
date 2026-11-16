import { createFileRoute } from '@tanstack/react-router'
import { LegalPage } from '../components/LegalPage'

export const Route = createFileRoute('/privacy')({
  component: () => <LegalPage kind="privacy" />,
  head: () => ({
    meta: [
      { title: 'Privacy Notice - Scoot Sales' },
      {
        name: 'description',
        content: 'Privacy notice for Scoot Sales workspaces, in English and Bahasa Malaysia.',
      },
    ],
  }),
})
