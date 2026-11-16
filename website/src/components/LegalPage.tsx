import { SiteFooter, SiteHeader } from './SiteChrome'

type LegalSection = {
  enTitle: string
  enBody: string
  msTitle: string
  msBody: string
}

const privacySections: LegalSection[] = [
  {
    enTitle: 'This public showcase',
    enBody: 'This website explains the Scoot Sales project. Its walkthrough selections run in your browser and do not submit orders or connect to a client workspace. It has no registration, payment or feedback submission form.',
    msTitle: 'Laman penerangan awam',
    msBody: 'Laman ini menerangkan projek Scoot Sales. Pilihan panduan berjalan dalam pelayar anda dan tidak menghantar pesanan atau menyambung ke ruang kerja pelanggan. Tiada borang pendaftaran, pembayaran atau penghantaran maklum balas.',
  },
  {
    enTitle: 'Product captures and demonstration data',
    enBody: 'The interface captures show team-entered simulation and testing records. Retailer names may refer to real entities in Kuching, but the displayed activity is not evidence of their commercial use or endorsement. Scout examples are illustrative explanations, not live responses from a client account.',
    msTitle: 'Paparan produk dan data demonstrasi',
    msBody: 'Paparan antara muka menunjukkan rekod simulasi dan pengujian yang dimasukkan oleh pasukan. Nama peruncit mungkin merujuk kepada entiti sebenar di Kuching, tetapi aktiviti yang dipaparkan bukan bukti penggunaan komersial atau sokongan mereka. Contoh Scout ialah penerangan ilustrasi, bukan respons langsung daripada akaun pelanggan.',
  },
  {
    enTitle: 'Inside an authorised workspace',
    enBody: 'The application handles operational records such as user accounts, retailer details, orders, visits and structured outcomes. Access depends on the authenticated user’s role and assignment. Product access is separate from this public website. Location evidence is supplementary and depends on the user enabling location sharing.',
    msTitle: 'Dalam ruang kerja yang dibenarkan',
    msBody: 'Aplikasi mengendalikan rekod operasi seperti akaun pengguna, butiran peruncit, pesanan, lawatan dan hasil lawatan berstruktur. Akses bergantung pada peranan dan penugasan pengguna yang disahkan. Akses produk adalah berasingan daripada laman awam ini. Bukti lokasi ialah maklumat tambahan dan bergantung pada pengguna mengaktifkan perkongsian lokasi.',
  },
  {
    enTitle: 'Before a client rollout',
    enBody: 'The operating organisation must confirm its privacy contact, hosting arrangements, retention periods and the process for handling access or correction requests before a client rollout. These details are not established by this design preview. Discuss data handling with the project team before supplying personal or client records.',
    msTitle: 'Sebelum pelaksanaan pelanggan',
    msBody: 'Organisasi pengendali perlu mengesahkan pegawai hubungan privasi, aturan pengehosan, tempoh penyimpanan dan proses permintaan akses atau pembetulan sebelum pelaksanaan pelanggan. Butiran ini belum ditetapkan melalui pratonton reka bentuk ini. Bincangkan pengendalian data dengan pasukan projek sebelum membekalkan rekod peribadi atau pelanggan.',
  },
]

const termsSections: LegalSection[] = [
  {
    enTitle: 'Purpose of this preview',
    enBody: 'This public website presents Scoot Sales for project evaluation and stakeholder discussion. It does not provide a production account, a purchase agreement or a service-level commitment. Any client rollout requires separately agreed operating terms.',
    msTitle: 'Tujuan pratonton ini',
    msBody: 'Laman awam ini memperkenalkan Scoot Sales untuk penilaian projek dan perbincangan pihak berkepentingan. Ia tidak menyediakan akaun pengeluaran, perjanjian pembelian atau komitmen tahap perkhidmatan. Pelaksanaan pelanggan memerlukan syarat operasi yang dipersetujui secara berasingan.',
  },
  {
    enTitle: 'Authorised product use',
    enBody: 'An application workspace is available only to authorised users. Use the role and assignment provided to you. Do not share account credentials, attempt to access another person’s records or enter confidential client data into an unapproved demonstration environment.',
    msTitle: 'Penggunaan produk yang dibenarkan',
    msBody: 'Ruang kerja aplikasi hanya tersedia kepada pengguna yang dibenarkan. Gunakan peranan dan penugasan yang diberikan. Jangan kongsi kelayakan akaun, cuba mengakses rekod orang lain atau masukkan data sulit pelanggan ke persekitaran demonstrasi yang belum diluluskan.',
  },
  {
    enTitle: 'Human decisions and estimates',
    enBody: 'Forecasts, retailer priorities, route scenarios and Scout explanations support human review. They do not guarantee sales, travel times or future demand. Authorised managers review and publish routes. Mobile Scout does not submit orders or change route plans.',
    msTitle: 'Keputusan manusia dan anggaran',
    msBody: 'Ramalan, keutamaan peruncit, senario laluan dan penerangan Scout menyokong semakan manusia. Ia tidak menjamin jualan, masa perjalanan atau permintaan masa hadapan. Pengurus yang dibenarkan menyemak dan menerbitkan laluan. Scout mudah alih tidak menghantar pesanan atau mengubah rancangan laluan.',
  },
  {
    enTitle: 'Reading the evidence',
    enBody: 'Screenshots use simulation and testing data. No client endorsement, measured productivity improvement or forecasting superiority is implied. The proposed 30% time-saving objective remains a target for controlled testing. Confirm current capability and evaluation evidence with the project team before an operational decision.',
    msTitle: 'Memahami bukti',
    msBody: 'Tangkapan skrin menggunakan data simulasi dan pengujian. Tiada sokongan pelanggan, peningkatan produktiviti terukur atau kelebihan ramalan yang tersirat. Objektif penjimatan masa 30% masih merupakan sasaran untuk pengujian terkawal. Sahkan keupayaan semasa dan bukti penilaian dengan pasukan projek sebelum membuat keputusan operasi.',
  },
]

export function LegalPage({ kind }: { kind: 'privacy' | 'terms' }) {
  const privacy = kind === 'privacy'
  const sections = privacy ? privacySections : termsSections
  const title = privacy ? 'Privacy notice' : 'Evaluation terms'

  return (
    <>
      <SiteHeader />
      <main className="page" id="main">
        <section className="legal-page wrap" aria-labelledby="legal-title">
          <h1 id="legal-title">{title}</h1>
          <p className="legal-intro">{privacy ? 'How to read this public showcase and its data context.' : 'The scope of this project preview and its demonstrations.'}</p>
          <div className="legal-note"><p>Evaluation draft · 16 October 2026. These pages provide a factual overview for this local preview. The operating organisation must review and approve the final notices before client use.</p><p lang="ms">Draf penilaian · 16 Oktober 2026. Organisasi pengendali perlu menyemak dan meluluskan notis akhir sebelum penggunaan pelanggan.</p></div>
          <div className="legal-sections">
            {sections.map((section) => (
              <section className="legal-section" key={section.enTitle}>
                <h2>{section.enTitle}</h2>
                <p lang="en">{section.enBody}</p>
                <span className="legal-language" lang="ms">{section.msTitle}</span>
                <p lang="ms">{section.msBody}</p>
              </section>
            ))}
          </div>
        </section>
      </main>
      <SiteFooter />
    </>
  )
}
