enum LegalDocumentKind { privacyPolicy, termsAndConditions }

enum LegalLanguage {
  english('English'),
  malay('Bahasa Malaysia');

  const LegalLanguage(this.label);

  final String label;
}

const String legalVersion = '2.1';
const String legalDate = '4 November 2026';
const String legalContactEmail = String.fromEnvironment(
  'LEGAL_CONTACT_EMAIL',
  defaultValue: '[REPLACE-CONTACT-EMAIL]',
);

class LegalSection {
  const LegalSection(this.heading, this.body);

  final String heading;
  final String body;
}

class LegalText {
  const LegalText({
    required this.title,
    required this.versionLabel,
    required this.sections,
  });

  final String title;
  final String versionLabel;
  final List<LegalSection> sections;

  String get versionLine => '$versionLabel $legalVersion · $legalDate';
}

LegalText legalText(
  LegalDocumentKind document,
  LegalLanguage language,
) => switch ((document, language)) {
  (LegalDocumentKind.privacyPolicy, LegalLanguage.english) => privacyEnglish,
  (LegalDocumentKind.privacyPolicy, LegalLanguage.malay) => privacyMalay,
  (LegalDocumentKind.termsAndConditions, LegalLanguage.english) => termsEnglish,
  (LegalDocumentKind.termsAndConditions, LegalLanguage.malay) => termsMalay,
};

String legalTitle(LegalDocumentKind document) =>
    legalText(document, LegalLanguage.english).title;

const LegalText privacyEnglish = LegalText(
  title: 'Privacy Policy',
  versionLabel: 'Version',
  sections: <LegalSection>[
    LegalSection(
      '1. About this policy',
      'This policy explains how Scoot Sales handles personal data in the company dashboard, the salesperson phone app and the Control Centre. It follows the Personal Data Protection Act 2010 of Malaysia (PDPA), as amended in 2024.\n'
          'If the English and Bahasa Malaysia texts differ, the English text applies.',
    ),
    LegalSection(
      '2. Who is responsible',
      'Your company uses Scoot Sales to run its sales work. Your company decides why and how its work data is used. Your company is the data user for that data. Scoot Sales processes it for your company under a data processing agreement.\n'
          'Scoot Sales is the data user for its own staff accounts, company billing records, support messages and security records.\n'
          'For work data, contact your company administrator first.',
    ),
    LegalSection(
      '3. Data we collect',
      '• Account data: name, work email, phone number, employee code, role, branch, supervisor, account status and an optional profile photo.\n'
          '• Sign-in data: sign-in records kept by Firebase Authentication. For Control Centre staff, also session records and backup codes. Backup codes are stored only as hashes.\n'
          '• Work data: retailers, products, orders, routes, stops, visit notes, skip reasons, visit outcomes, score sheets and special requests.\n'
          '• Signatures: a retailer contact can sign an order on the phone. The drawn signature is stored with the visit record.\n'
          '• Location: see section 5.\n'
          '• Billing data: company name, billing email, invoices, payments and receipts.\n'
          '• Technical data: server logs, audit records and your network address. We use a hashed form of the address to limit abuse. These limit records are deleted after 30 days.',
    ),
    LegalSection(
      '4. Why we use it',
      '• To run the service for your company: sign-in, access by role, routes, orders, visits, forecasts and reports.\n'
          '• To show your supervisor where you are during work, and to confirm arrival at a retailer.\n'
          '• To send email: invitations, sign-in codes, invoices, receipts and service notices.\n'
          '• To bill your company.\n'
          '• To keep the service safe: audit records, abuse checks and incident response.\n'
          '• To meet legal duties.\n'
          'We do not sell personal data. We do not use it for advertising.',
    ),
    LegalSection(
      '5. Location during work',
      'The phone app records your location only when all of these are true: you have an active work session, Location sharing is on in Profile, and the phone allows location access.\n'
          'It records latitude, longitude, accuracy, time, and a flag that shows if the position looks faked.\n'
          'Your supervisor, your branch manager and your company administrators can see it. Scoot Sales staff do not see it.\n'
          'The position saved with an order is kept for 1 year. All other location data is deleted after 30 days: the trail of positions, the live position, the position saved as proof of arrival, and the last known position on your profile. Exports follow the same periods.\n'
          'You can turn Location sharing off at any time. Your company may then ask you to confirm arrivals by hand.',
    ),
    LegalSection(
      '6. Service providers',
      'We use these providers. Each one receives only the data it needs.\n'
          '• Google Firebase (Authentication, Firestore database, App Check): stores your company’s data in the region chosen when its Firebase project was created, for example Singapore (asia-southeast1).\n'
          '• Brevo: sends our email (invitations, sign-in codes, invoices, receipts and notices). Brevo receives the recipient address and the email content.\n'
          '• Google Gemini (Scout on the dashboard and the assistant in the phone app): when you type a request, the sentence you typed and the names of the pages and actions open to you are sent to Google. We use a paid, billed API key. Under Google’s paid API terms, Google does not use this data to train its models. Our server does not store the sentence you typed. Do not type personal data that the assistant does not need.\n'
          '• Google sign-in (web only): if you press Continue with Google on the dashboard or the Control Centre, Google confirms who you are and gives us your name and email address.\n'
          '• Firebase App Check (phone app): checks that requests come from our real app. It uses Play Integrity on Android, App Attest on iOS and reCAPTCHA Enterprise in a browser. It uses signals from your device or browser.\n'
          '• DigitalOcean: runs our server in Singapore.\n'
          '• Map services: the dashboard uses Geoapify for maps and road distances, and the phone app uses OpenStreetMap for maps. They receive the map area and your network address. For road distances, Geoapify also receives the positions of the stops.\n'
          '• Your browser’s speech service (dashboard voice commands): turns a spoken command into text. We do not keep audio or transcripts.',
    ),
    LegalSection(
      '7. Transfers outside Malaysia',
      'Some providers store or process data outside Malaysia, for example in Singapore, the United States or the European Union. We transfer personal data outside Malaysia only as section 129 of the PDPA allows. We use contracts and security measures to protect it.',
    ),
    LegalSection(
      '8. Legal basis and consent',
      'We follow the seven PDPA principles: General, Notice and Choice, Disclosure, Security, Retention, Data Integrity, and Access.\n'
          'Your company gets your consent, or relies on another basis that the PDPA allows, before your data is processed. You can withdraw consent. Tell your company in writing. If you withdraw consent, you may not be able to use the app for work.\n'
          'Your account data and work data are needed to use the service. Location sharing is your choice.',
    ),
    LegalSection(
      '9. Security',
      '• Each company has its own database project. One company cannot read the data of another company.\n'
          '• Access rules limit each person to their role and scope.\n'
          '• All connections use HTTPS.\n'
          '• Control Centre staff sign in with a password and an emailed code, or with Google. A staff session ends after 12 hours.\n'
          '• Scoot Sales staff have no standing access to company data. A company administrator can give a read-only support grant for 5 to 60 minutes. Each grant is logged.\n'
          '• Risky staff actions need a second person to approve them.\n'
          '• An automatic job checks our audit log every hour.\n'
          'No system is fully safe. If a breach happens, we follow our incident plan and the PDPA.',
    ),
    LegalSection(
      '10. How long we keep data',
      '• GPS position saved with an order: 1 year.\n'
          '• All other GPS data (trail, live position, arrival position, last position on the profile): 30 days.\n'
          '• Account data: while the account exists. Deleted 30 days after an accepted deletion request (section 11).\n'
          '• Orders and audit logs: 7 years by default. Your company administrator may choose a shorter period for orders. Visit logs: 2 years. Routes and other work records: while your company uses the service.\n'
          '• After your company’s subscription is suspended, expires or is cancelled: administrators can read and export data for 90 days. Then the data is deleted.\n'
          '• Invoices and payment records: as long as Malaysian law requires.\n'
          'When we no longer need data, we delete it or make it anonymous.',
    ),
    LegalSection(
      '11. Deleting your account',
      'A salesperson can ask to delete the account in the phone app, in Profile. The app signs you out and tells your company administrators.\n'
          'You can cancel the request within 30 days. After 30 days, we delete your location trail, last position, tracking settings, invitation records, sign-in account, access record and profile. In work records such as orders, routes and visits, your name becomes "Deleted user" and your email is removed. The work records stay because your company needs them.\n'
          'A company administrator can choose "Delete now". Your sign-in stays off and the account is hidden at once. The administrator can restore the account for 7 days. After 7 days, the data above is deleted for good.\n'
          'Administrator accounts are not deleted from the app. A company administrator can ask Scoot Sales for deletion.',
    ),
    LegalSection(
      '12. Data export',
      'A company administrator can download a data export. It is a ZIP file with CSV and JSON files. It covers users and their access records, products, retailers, orders, routes, route and stop progress, visit outcomes and score sheets.',
    ),
    LegalSection(
      '13. Your rights',
      'Under the PDPA you can:\n'
          '• ask to see the personal data we hold about you (access);\n'
          '• ask us to correct data that is wrong (correction);\n'
          '• withdraw consent;\n'
          '• ask us to limit how we use your data;\n'
          '• ask for a copy of your data in a form you can move (data portability);\n'
          '• complain to the Personal Data Protection Commissioner (JPDP).\n'
          'For work data, ask your company administrator first. We help your company reply within 21 days. We may ask you to prove who you are.',
    ),
    LegalSection(
      '14. Children',
      'Scoot Sales is for work use by adults. We do not knowingly collect data about anyone under 18.',
    ),
    LegalSection(
      '15. Cookies and browser storage',
      'The web apps use browser storage to keep you signed in and to remember settings. We do not use advertising cookies.',
    ),
    LegalSection(
      '16. Changes to this policy',
      'We may change this policy. The version and date at the top show which copy you are reading. Before a large change, we tell companies by email.',
    ),
    LegalSection(
      '17. Contact',
      'Work data: your company administrator.\n'
          'Scoot Sales privacy, support and security contact: $legalContactEmail\n'
          'Regulator: Jabatan Perlindungan Data Peribadi (JPDP), Malaysia.',
    ),
  ],
);

const LegalText privacyMalay = LegalText(
  title: 'Dasar Privasi',
  versionLabel: 'Versi',
  sections: <LegalSection>[
    LegalSection(
      '1. Tentang dasar ini',
      'Dasar ini menerangkan cara Scoot Sales mengendalikan data peribadi dalam papan pemuka syarikat, aplikasi telefon jurujual dan Pusat Kawalan. Dasar ini mematuhi Akta Perlindungan Data Peribadi 2010 Malaysia (PDPA), seperti yang dipinda pada tahun 2024.\n'
          'Jika teks bahasa Inggeris dan Bahasa Malaysia berbeza, teks bahasa Inggeris terpakai.',
    ),
    LegalSection(
      '2. Siapa yang bertanggungjawab',
      'Syarikat anda menggunakan Scoot Sales untuk menjalankan kerja jualannya. Syarikat anda menentukan sebab dan cara data kerjanya digunakan. Syarikat anda ialah pengguna data bagi data tersebut. Scoot Sales memproses data itu bagi pihak syarikat anda di bawah perjanjian pemprosesan data.\n'
          'Scoot Sales ialah pengguna data bagi akaun kakitangannya sendiri, rekod bil syarikat, mesej sokongan dan rekod keselamatan.\n'
          'Untuk data kerja, hubungi pentadbir syarikat anda dahulu.',
    ),
    LegalSection(
      '3. Data yang kami kumpul',
      '• Data akaun: nama, e-mel kerja, nombor telefon, kod pekerja, peranan, cawangan, penyelia, status akaun dan foto profil pilihan.\n'
          '• Data log masuk: rekod log masuk yang disimpan oleh Firebase Authentication. Bagi kakitangan Pusat Kawalan, juga rekod sesi dan kod sandaran. Kod sandaran disimpan hanya dalam bentuk cincang.\n'
          '• Data kerja: peruncit, produk, pesanan, laluan, hentian, nota lawatan, sebab langkau, hasil lawatan, helaian skor dan permintaan khas.\n'
          '• Tandatangan: wakil peruncit boleh menandatangani pesanan pada telefon. Tandatangan yang dilukis disimpan bersama rekod lawatan.\n'
          '• Lokasi: lihat bahagian 5.\n'
          '• Data bil: nama syarikat, e-mel bil, invois, bayaran dan resit.\n'
          '• Data teknikal: log pelayan, rekod audit dan alamat rangkaian anda. Kami menggunakan bentuk cincang alamat itu untuk menghadkan penyalahgunaan. Rekod had ini dipadam selepas 30 hari.',
    ),
    LegalSection(
      '4. Mengapa kami menggunakannya',
      '• Untuk menjalankan perkhidmatan bagi syarikat anda: log masuk, akses mengikut peranan, laluan, pesanan, lawatan, ramalan dan laporan.\n'
          '• Untuk menunjukkan kepada penyelia anda di mana anda berada semasa kerja, dan untuk mengesahkan ketibaan di peruncit.\n'
          '• Untuk menghantar e-mel: jemputan, kod log masuk, invois, resit dan notis perkhidmatan.\n'
          '• Untuk mengebil syarikat anda.\n'
          '• Untuk memastikan perkhidmatan selamat: rekod audit, semakan penyalahgunaan dan tindak balas insiden.\n'
          '• Untuk memenuhi kewajipan undang-undang.\n'
          'Kami tidak menjual data peribadi. Kami tidak menggunakannya untuk pengiklanan.',
    ),
    LegalSection(
      '5. Lokasi semasa kerja',
      'Aplikasi telefon merekod lokasi anda hanya apabila semua perkara ini benar: anda mempunyai sesi kerja yang aktif, Perkongsian lokasi dihidupkan dalam Profil, dan telefon membenarkan akses lokasi.\n'
          'Ia merekod latitud, longitud, ketepatan, masa, dan tanda yang menunjukkan jika kedudukan kelihatan dipalsukan.\n'
          'Penyelia anda, pengurus cawangan anda dan pentadbir syarikat anda boleh melihatnya. Kakitangan Scoot Sales tidak melihatnya.\n'
          'Kedudukan yang direkodkan bersama pesanan dikekalkan selama 1 tahun. Semua data lokasi lain dipadam selepas 30 hari: jejak kedudukan, kedudukan semasa, kedudukan yang disimpan sebagai bukti ketibaan, dan kedudukan terakhir pada profil anda. Eksport mengikut tempoh yang sama.\n'
          'Anda boleh mematikan Perkongsian lokasi pada bila-bila masa. Syarikat anda mungkin kemudian meminta anda mengesahkan ketibaan secara manual.',
    ),
    LegalSection(
      '6. Penyedia perkhidmatan',
      'Kami menggunakan penyedia ini. Setiap penyedia menerima hanya data yang diperlukannya.\n'
          '• Google Firebase (Authentication, pangkalan data Firestore, App Check): menyimpan data syarikat anda di rantau yang dipilih semasa projek Firebase syarikat dibuat, contohnya Singapura (asia-southeast1).\n'
          '• Brevo: menghantar e-mel kami (jemputan, kod log masuk, invois, resit dan notis). Brevo menerima alamat penerima dan kandungan e-mel.\n'
          '• Google Gemini (Scout pada papan pemuka dan pembantu dalam aplikasi telefon): apabila anda menaip permintaan, ayat yang anda taip dan nama halaman serta tindakan yang terbuka kepada anda dihantar kepada Google. Kami menggunakan kunci API berbayar. Di bawah terma API berbayar Google, Google tidak menggunakan data ini untuk melatih modelnya. Pelayan kami tidak menyimpan ayat yang anda taip. Jangan taip data peribadi yang tidak diperlukan oleh pembantu.\n'
          '• Log masuk Google (web sahaja): jika anda menekan Continue with Google pada papan pemuka atau Pusat Kawalan, Google mengesahkan identiti anda dan memberikan nama dan alamat e-mel anda kepada kami.\n'
          '• Firebase App Check (aplikasi telefon): menyemak bahawa permintaan datang daripada aplikasi kami yang sebenar. Ia menggunakan Play Integrity pada Android, App Attest pada iOS dan reCAPTCHA Enterprise dalam pelayar. Ia menggunakan isyarat daripada peranti atau pelayar anda.\n'
          '• DigitalOcean: menjalankan pelayan kami di Singapura.\n'
          '• Perkhidmatan peta: papan pemuka menggunakan Geoapify untuk peta dan jarak jalan, dan aplikasi telefon menggunakan OpenStreetMap untuk peta. Perkhidmatan ini menerima kawasan peta dan alamat rangkaian anda. Untuk jarak jalan, Geoapify juga menerima kedudukan hentian.\n'
          '• Perkhidmatan pertuturan pelayar anda (arahan suara papan pemuka): menukar arahan yang disebut kepada teks. Kami tidak menyimpan audio atau transkrip.',
    ),
    LegalSection(
      '7. Pemindahan ke luar Malaysia',
      'Sesetengah penyedia menyimpan atau memproses data di luar Malaysia, contohnya di Singapura, Amerika Syarikat atau Kesatuan Eropah. Kami memindahkan data peribadi ke luar Malaysia hanya seperti yang dibenarkan oleh seksyen 129 PDPA. Kami menggunakan kontrak dan langkah keselamatan untuk melindunginya.',
    ),
    LegalSection(
      '8. Asas undang-undang dan persetujuan',
      'Kami mematuhi tujuh prinsip PDPA: Prinsip Am, Notis dan Pilihan, Penzahiran, Keselamatan, Penyimpanan, Integriti Data, dan Akses.\n'
          'Syarikat anda mendapatkan persetujuan anda, atau bergantung pada asas lain yang dibenarkan oleh PDPA, sebelum data anda diproses. Anda boleh menarik balik persetujuan. Beritahu syarikat anda secara bertulis. Jika anda menarik balik persetujuan, anda mungkin tidak dapat menggunakan aplikasi untuk kerja.\n'
          'Data akaun dan data kerja anda diperlukan untuk menggunakan perkhidmatan. Perkongsian lokasi ialah pilihan anda.',
    ),
    LegalSection(
      '9. Keselamatan',
      '• Setiap syarikat mempunyai projek pangkalan data sendiri. Satu syarikat tidak boleh membaca data syarikat lain.\n'
          '• Peraturan akses mengehadkan setiap orang kepada peranan dan skopnya.\n'
          '• Semua sambungan menggunakan HTTPS.\n'
          '• Kakitangan Pusat Kawalan log masuk dengan kata laluan dan kod yang dihantar melalui e-mel, atau dengan Google. Sesi kakitangan tamat selepas 12 jam.\n'
          '• Kakitangan Scoot Sales tidak mempunyai akses tetap kepada data syarikat. Pentadbir syarikat boleh memberikan geran sokongan baca sahaja selama 5 hingga 60 minit. Setiap geran direkodkan.\n'
          '• Tindakan kakitangan yang berisiko memerlukan kelulusan orang kedua.\n'
          '• Satu tugas automatik menyemak log audit kami setiap jam.\n'
          'Tiada sistem yang selamat sepenuhnya. Jika berlaku pelanggaran, kami mengikut pelan insiden kami dan PDPA.',
    ),
    LegalSection(
      '10. Berapa lama kami menyimpan data',
      '• Kedudukan GPS yang direkodkan bersama pesanan: 1 tahun.\n'
          '• Semua data GPS lain (jejak, kedudukan semasa, kedudukan ketibaan, kedudukan terakhir pada profil): 30 hari.\n'
          '• Data akaun: selagi akaun wujud. Dipadam 30 hari selepas permintaan pemadaman diterima (bahagian 11).\n'
          '• Pesanan dan log audit: 7 tahun secara lalai. Pentadbir syarikat anda boleh memilih tempoh yang lebih pendek untuk pesanan. Log lawatan: 2 tahun. Laluan dan rekod kerja lain: selagi syarikat anda menggunakan perkhidmatan.\n'
          '• Selepas langganan syarikat anda digantung, tamat tempoh atau dibatalkan: pentadbir boleh membaca dan mengeksport data selama 90 hari. Kemudian data dipadam.\n'
          '• Invois dan rekod bayaran: selama yang dikehendaki oleh undang-undang Malaysia.\n'
          'Apabila kami tidak lagi memerlukan data, kami memadamnya atau menjadikannya tanpa nama.',
    ),
    LegalSection(
      '11. Memadam akaun anda',
      'Jurujual boleh meminta pemadaman akaun dalam aplikasi telefon, di Profil. Aplikasi melog keluar anda dan memberitahu pentadbir syarikat anda.\n'
          'Anda boleh membatalkan permintaan dalam tempoh 30 hari. Selepas 30 hari, kami memadam jejak lokasi, kedudukan terakhir, tetapan penjejakan, rekod jemputan, akaun log masuk, rekod akses dan profil anda. Dalam rekod kerja seperti pesanan, laluan dan lawatan, nama anda menjadi "Deleted user" dan e-mel anda dibuang. Rekod kerja kekal kerana syarikat anda memerlukannya.\n'
          'Pentadbir syarikat boleh memilih "Padam sekarang". Log masuk anda kekal dimatikan dan akaun disembunyikan serta-merta. Pentadbir boleh memulihkan akaun dalam tempoh 7 hari. Selepas 7 hari, data di atas dipadam secara kekal.\n'
          'Akaun pentadbir tidak dipadam daripada aplikasi. Pentadbir syarikat boleh meminta Scoot Sales untuk memadamnya.',
    ),
    LegalSection(
      '12. Eksport data',
      'Pentadbir syarikat boleh memuat turun eksport data. Eksport ialah fail ZIP dengan fail CSV dan JSON. Eksport merangkumi pengguna dan rekod akses mereka, produk, peruncit, pesanan, laluan, kemajuan laluan dan hentian, hasil lawatan dan helaian skor.',
    ),
    LegalSection(
      '13. Hak anda',
      'Di bawah PDPA anda boleh:\n'
          '• meminta untuk melihat data peribadi yang kami simpan tentang anda (akses);\n'
          '• meminta kami membetulkan data yang salah (pembetulan);\n'
          '• menarik balik persetujuan;\n'
          '• meminta kami mengehadkan cara kami menggunakan data anda;\n'
          '• meminta salinan data anda dalam bentuk yang boleh dipindahkan (kemudahalihan data);\n'
          '• membuat aduan kepada Pesuruhjaya Perlindungan Data Peribadi (JPDP).\n'
          'Untuk data kerja, tanya pentadbir syarikat anda dahulu. Kami membantu syarikat anda menjawab dalam tempoh 21 hari. Kami mungkin meminta anda membuktikan identiti anda.',
    ),
    LegalSection(
      '14. Kanak-kanak',
      'Scoot Sales adalah untuk kegunaan kerja oleh orang dewasa. Kami tidak dengan sengaja mengumpul data tentang sesiapa yang berumur bawah 18 tahun.',
    ),
    LegalSection(
      '15. Kuki dan storan pelayar',
      'Aplikasi web menggunakan storan pelayar untuk memastikan anda kekal log masuk dan untuk mengingati tetapan. Kami tidak menggunakan kuki pengiklanan.',
    ),
    LegalSection(
      '16. Perubahan pada dasar ini',
      'Kami mungkin mengubah dasar ini. Versi dan tarikh di bahagian atas menunjukkan salinan yang anda baca. Sebelum perubahan besar, kami memberitahu syarikat melalui e-mel.',
    ),
    LegalSection(
      '17. Hubungi kami',
      'Data kerja: pentadbir syarikat anda.\n'
          'Hubungan privasi, sokongan dan keselamatan Scoot Sales: $legalContactEmail\n'
          'Pengawal selia: Jabatan Perlindungan Data Peribadi (JPDP), Malaysia.',
    ),
  ],
);

const LegalText termsEnglish = LegalText(
  title: 'Terms & Conditions',
  versionLabel: 'Version',
  sections: <LegalSection>[
    LegalSection(
      '1. About these terms',
      'These terms apply to the Scoot Sales company dashboard, the salesperson phone app and the Control Centre. They are an agreement between Scoot Sales and the company that subscribes ("your company"). Every user must also follow them.\n'
          'If the English and Bahasa Malaysia texts differ, the English text applies.',
    ),
    LegalSection(
      '2. The service',
      'Scoot Sales helps FMCG companies manage sales work. It has:\n'
          '• a web dashboard for administrators, branch managers and supervisors;\n'
          '• a phone app for salespeople;\n'
          '• forecasts, route suggestions and Scout, an assistant that makes suggestions;\n'
          '• a Control Centre that only Scoot Sales staff use.\n'
          'We may add, change or remove features. We tell your company before we remove a feature that it pays for.',
    ),
    LegalSection(
      '3. Accounts and roles',
      'Your company administrator invites users and gives each one a role: administrator, branch manager, supervisor or salesperson. Each role sees only the data that its scope allows.\n'
          'Each person gets a personal account. Do not share your account or password. Keep your sign-in details safe. If you think someone else used your account, tell your administrator at once.\n'
          'The number of users depends on your company’s package. The service refuses new users above the limit.',
    ),
    LegalSection(
      '4. Acceptable use',
      'Use Scoot Sales only for the lawful sales work of your company. Do not:\n'
          '• try to read data that you are not allowed to see, including the data of another company;\n'
          '• bypass access rules or security checks;\n'
          '• probe, attack or overload the service;\n'
          '• upload unlawful or harmful content;\n'
          '• enter false orders, visits or locations, or use tools that fake your location;\n'
          '• copy, resell or rebuild the service.',
    ),
    LegalSection(
      '5. Company administrator duties',
      'Your company administrator must:\n'
          '• keep the list of users and roles correct, and remove people who leave;\n'
          '• tell salespeople about location tracking before it starts, and have a lawful basis for it;\n'
          '• use location only during work and only for the stated purpose;\n'
          '• answer requests from its people about their data;\n'
          '• keep its own data exports of records that it cannot lose;\n'
          '• give support grants to Scoot Sales staff only when needed.',
    ),
    LegalSection(
      '6. Packages and payment',
      'The packages are Starter, Standard and Professional. Enterprise is priced by quote. The order form states the package, the limits, the price in Malaysian Ringgit and the billing period.\n'
          'We send an invoice before each period. Your company pays by bank transfer with the payment reference on the invoice. A second Scoot Sales staff member checks each payment before we send a receipt. We send reminders 14 days and 3 days before the paid period ends.',
    ),
    LegalSection(
      '7. Late payment and suspension',
      'If the paid period ends without a checked payment, the workspace becomes past due. Everything still works, and we send reminders.\n'
          'If payment is still missing 14 days later, Scoot Sales staff may suspend the workspace. When a workspace is suspended:\n'
          '• salespeople are signed out of the phone app;\n'
          '• work saved on a phone before the suspension can still upload for 24 hours. Work done after the suspension is not accepted;\n'
          '• administrators can sign in read-only and download the data export.\n'
          'We reactivate the workspace after a checked payment covers the period. After a suspension, expiry or cancellation, administrators have 90 days to export data.',
    ),
    LegalSection(
      '8. Suspension for other reasons',
      'We may suspend a workspace at once if its use is a risk to other users, or breaks the law or these terms. A forced suspension needs the approval of two Scoot Sales staff. We tell your company the reason.',
    ),
    LegalSection(
      '9. Forecasts, suggestions and Scout',
      'Forecasts, rankings, route suggestions, voice commands and Scout give decision support only. They can be wrong. They never change a published route or its progress by themselves. Scout only proposes an action. You confirm it before it runs. Your company decides what to do and is responsible for its business decisions.\n'
          'The assistant may be unavailable. Then the dashboard shows: The assistant did not answer this time. The phone app shows: The assistant did not answer this time. Ask again, or try one of these.',
    ),
    LegalSection(
      '10. Availability and support',
      'We work to keep the service available. We do not promise that it is always available or free of faults. We try to tell your company in advance about planned work that stops the service.\n'
          'The phone app keeps working offline with saved data. Some actions need a connection, for example first sign-in and invitations. Email delivery depends on Brevo and may be late.',
    ),
    LegalSection(
      '11. Your company’s data',
      'Your company owns the data that it puts into Scoot Sales. We process it only to provide the service and as your company instructs, under the data processing agreement and the Privacy Policy. Scoot Sales staff do not look at company data unless the law requires it or an administrator gives a support grant.',
    ),
    LegalSection(
      '12. Liability',
      'We provide the service as it is, as far as the law allows. We are not liable for loss of profit, indirect loss, or loss of data that your company could have exported. Our total liability in any 12 months is limited to the fees that your company paid in those 12 months. Nothing in these terms limits a liability that the law does not allow us to limit.',
    ),
    LegalSection(
      '13. Changes to these terms',
      'We may change these terms. We tell your company by email at least 30 days before a change starts. If your company does not agree, it may end the agreement before the change starts.',
    ),
    LegalSection(
      '14. Governing law',
      'The laws of Malaysia govern these terms. The courts of Malaysia decide disputes. [Court location to be confirmed.]',
    ),
    LegalSection(
      '15. Contact',
      'Questions about your account or work data: your company administrator.\n'
          'Questions about these terms: $legalContactEmail',
    ),
  ],
);

const LegalText termsMalay = LegalText(
  title: 'Terma & Syarat',
  versionLabel: 'Versi',
  sections: <LegalSection>[
    LegalSection(
      '1. Tentang terma ini',
      'Terma ini terpakai kepada papan pemuka syarikat Scoot Sales, aplikasi telefon jurujual dan Pusat Kawalan. Terma ini ialah perjanjian antara Scoot Sales dan syarikat yang melanggan ("syarikat anda"). Setiap pengguna juga mesti mematuhinya.\n'
          'Jika teks bahasa Inggeris dan Bahasa Malaysia berbeza, teks bahasa Inggeris terpakai.',
    ),
    LegalSection(
      '2. Perkhidmatan',
      'Scoot Sales membantu syarikat FMCG mengurus kerja jualan. Ia mempunyai:\n'
          '• papan pemuka web untuk pentadbir, pengurus cawangan dan penyelia;\n'
          '• aplikasi telefon untuk jurujual;\n'
          '• ramalan, cadangan laluan dan Scout, pembantu yang memberikan cadangan;\n'
          '• Pusat Kawalan yang hanya digunakan oleh kakitangan Scoot Sales.\n'
          'Kami mungkin menambah, mengubah atau membuang ciri. Kami memberitahu syarikat anda sebelum kami membuang ciri yang dibayarnya.',
    ),
    LegalSection(
      '3. Akaun dan peranan',
      'Pentadbir syarikat anda menjemput pengguna dan memberikan setiap pengguna satu peranan: pentadbir, pengurus cawangan, penyelia atau jurujual. Setiap peranan hanya melihat data yang dibenarkan oleh skopnya.\n'
          'Setiap orang mendapat akaun peribadi. Jangan kongsi akaun atau kata laluan anda. Simpan butiran log masuk anda dengan selamat. Jika anda fikir orang lain telah menggunakan akaun anda, beritahu pentadbir anda dengan segera.\n'
          'Bilangan pengguna bergantung pada pakej syarikat anda. Perkhidmatan menolak pengguna baharu yang melebihi had.',
    ),
    LegalSection(
      '4. Penggunaan yang dibenarkan',
      'Gunakan Scoot Sales hanya untuk kerja jualan syarikat anda yang sah. Jangan:\n'
          '• cuba membaca data yang anda tidak dibenarkan lihat, termasuk data syarikat lain;\n'
          '• memintas peraturan akses atau semakan keselamatan;\n'
          '• menguji, menyerang atau membebankan perkhidmatan;\n'
          '• memuat naik kandungan yang menyalahi undang-undang atau berbahaya;\n'
          '• memasukkan pesanan, lawatan atau lokasi palsu, atau menggunakan alat yang memalsukan lokasi anda;\n'
          '• menyalin, menjual semula atau membina semula perkhidmatan.',
    ),
    LegalSection(
      '5. Tanggungjawab pentadbir syarikat',
      'Pentadbir syarikat anda mesti:\n'
          '• memastikan senarai pengguna dan peranan betul, dan membuang orang yang telah berhenti;\n'
          '• memberitahu jurujual tentang penjejakan lokasi sebelum ia bermula, dan mempunyai asas yang sah untuknya;\n'
          '• menggunakan lokasi hanya semasa kerja dan hanya untuk tujuan yang dinyatakan;\n'
          '• menjawab permintaan daripada pekerjanya tentang data mereka;\n'
          '• menyimpan eksport data sendiri bagi rekod yang tidak boleh hilang;\n'
          '• memberikan geran sokongan kepada kakitangan Scoot Sales hanya apabila perlu.',
    ),
    LegalSection(
      '6. Pakej dan bayaran',
      'Pakej yang ada ialah Starter, Standard dan Professional. Harga Enterprise mengikut sebut harga. Borang pesanan menyatakan pakej, had, harga dalam Ringgit Malaysia dan tempoh bil.\n'
          'Kami menghantar invois sebelum setiap tempoh. Syarikat anda membayar melalui pindahan bank dengan rujukan bayaran pada invois. Seorang lagi kakitangan Scoot Sales menyemak setiap bayaran sebelum kami menghantar resit. Kami menghantar peringatan 14 hari dan 3 hari sebelum tempoh berbayar tamat.',
    ),
    LegalSection(
      '7. Lewat bayar dan penggantungan',
      'Jika tempoh berbayar tamat tanpa bayaran yang telah disemak, ruang kerja menjadi tertunggak. Semua masih berfungsi, dan kami menghantar peringatan.\n'
          'Jika bayaran masih belum diterima 14 hari kemudian, kakitangan Scoot Sales boleh menggantung ruang kerja. Apabila ruang kerja digantung:\n'
          '• jurujual dilog keluar daripada aplikasi telefon;\n'
          '• kerja yang disimpan pada telefon sebelum penggantungan masih boleh dimuat naik selama 24 jam. Kerja yang dibuat selepas penggantungan tidak diterima;\n'
          '• pentadbir boleh log masuk dalam mod baca sahaja dan memuat turun eksport data.\n'
          'Kami mengaktifkan semula ruang kerja selepas bayaran yang telah disemak meliputi tempoh tersebut. Selepas penggantungan, tamat tempoh atau pembatalan, pentadbir mempunyai 90 hari untuk mengeksport data.',
    ),
    LegalSection(
      '8. Penggantungan atas sebab lain',
      'Kami boleh menggantung ruang kerja dengan serta-merta jika penggunaannya membahayakan pengguna lain, atau melanggar undang-undang atau terma ini. Penggantungan paksa memerlukan kelulusan dua kakitangan Scoot Sales. Kami memberitahu syarikat anda sebabnya.',
    ),
    LegalSection(
      '9. Ramalan, cadangan dan Scout',
      'Ramalan, kedudukan, cadangan laluan, arahan suara dan Scout hanya memberikan sokongan keputusan. Hasilnya boleh salah. Ciri-ciri ini tidak pernah mengubah laluan yang telah diterbitkan atau kemajuannya dengan sendiri. Scout hanya mencadangkan tindakan. Anda mengesahkannya sebelum ia dijalankan. Syarikat anda menentukan apa yang perlu dilakukan dan bertanggungjawab atas keputusan perniagaannya.\n'
          'Pembantu mungkin tidak tersedia. Jika begitu, papan pemuka memaparkan: The assistant did not answer this time. Aplikasi telefon memaparkan: The assistant did not answer this time. Ask again, or try one of these.',
    ),
    LegalSection(
      '10. Ketersediaan dan sokongan',
      'Kami berusaha memastikan perkhidmatan tersedia. Kami tidak berjanji bahawa ia sentiasa tersedia atau bebas daripada kerosakan. Kami cuba memberitahu syarikat anda lebih awal tentang kerja terancang yang menghentikan perkhidmatan.\n'
          'Aplikasi telefon terus berfungsi di luar talian dengan data yang telah disimpan. Sesetengah tindakan memerlukan sambungan, contohnya log masuk kali pertama dan jemputan. Penghantaran e-mel bergantung pada Brevo dan mungkin lewat.',
    ),
    LegalSection(
      '11. Data syarikat anda',
      'Syarikat anda memiliki data yang dimasukkannya ke dalam Scoot Sales. Kami memproses data itu hanya untuk menyediakan perkhidmatan dan mengikut arahan syarikat anda, di bawah perjanjian pemprosesan data dan Dasar Privasi. Kakitangan Scoot Sales tidak melihat data syarikat kecuali jika dikehendaki oleh undang-undang atau pentadbir memberikan geran sokongan.',
    ),
    LegalSection(
      '12. Liabiliti',
      'Kami menyediakan perkhidmatan seadanya, setakat yang dibenarkan oleh undang-undang. Kami tidak bertanggungjawab atas kehilangan keuntungan, kerugian tidak langsung, atau kehilangan data yang boleh dieksport oleh syarikat anda. Jumlah liabiliti kami dalam mana-mana tempoh 12 bulan dihadkan kepada yuran yang dibayar oleh syarikat anda dalam tempoh 12 bulan tersebut. Tiada apa-apa dalam terma ini yang mengehadkan liabiliti yang tidak boleh dihadkan menurut undang-undang.',
    ),
    LegalSection(
      '13. Perubahan pada terma ini',
      'Kami mungkin mengubah terma ini. Kami memberitahu syarikat anda melalui e-mel sekurang-kurangnya 30 hari sebelum perubahan bermula. Jika syarikat anda tidak bersetuju, syarikat anda boleh menamatkan perjanjian sebelum perubahan bermula.',
    ),
    LegalSection(
      '14. Undang-undang yang mentadbir',
      'Undang-undang Malaysia mentadbir terma ini. Mahkamah Malaysia memutuskan pertikaian. [Lokasi mahkamah akan disahkan.]',
    ),
    LegalSection(
      '15. Hubungi kami',
      'Soalan tentang akaun atau data kerja anda: pentadbir syarikat anda.\n'
          'Soalan tentang terma ini: $legalContactEmail',
    ),
  ],
);
