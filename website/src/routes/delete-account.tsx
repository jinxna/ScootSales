import { createFileRoute } from '@tanstack/react-router'
import { DeleteAccountPage } from '../components/DeleteAccountPage'

export const Route = createFileRoute('/delete-account')({
  component: DeleteAccountPage,
  head: () => ({
    meta: [
      { title: 'Delete your account - Scoot Sales' },
      {
        name: 'description',
        content: 'How to ask for your Scoot Sales account and personal data to be deleted.',
      },
    ],
  }),
})
