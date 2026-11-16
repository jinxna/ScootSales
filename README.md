# Scoot Sales

Scoot Sales is a sales-management system for companies that sell fast-moving consumer goods. Administrators, branch managers and supervisors plan routes and review orders in a web dashboard. Salespeople visit retailers and take orders in a phone app. A central service and a staff Control Centre manage the companies that use the system.

## What is in each folder

| Folder or file | What it is |
|---|---|
| `admin_dashboard/` | The company web dashboard (Flutter web) and the staff Control Centre (`lib/control_centre/main.dart`). Also holds the Firestore rules and indexes. |
| `flutter_mobile_app/` | The salesperson phone app (Flutter, Android). |
| `platform_service/` | The central service (Python): companies, plans, invoices, staff sign-in and mail. |
| `forecasting/` | Demand forecasting and sales intelligence (Python). |
| `tools/voice/` | The voice and text assistant server and its shared code. |
| `packages/` | Dart packages shared by the apps. |
| `contracts/` | Sample data files that the tests use. |
| `deploy/` | Scripts and templates to install the services on a Linux server. |
| `website/` | The product website. |
| `faq/` | The source of the FAQ that the help pages show. |
| `e2e/` | End-to-end tests that drive the real apps in a browser and on an Android device. |
| `firestore_rules_test/` | Tests for the Firestore security rules. |
| `test/` | Tests for the local development server. |
| `scripts/` | Checks, release tools and operator tools. |
| `START.bat` | Starts the apps on your computer (Windows). |
| `server.js`, `runner.py`, `Dockerfile`, `Dockerfile.ai-runner`, `docker-compose.yml` | Local development server, the sales-intelligence runner, and container files. |
| `package.json`, `pytest.ini` | Settings for the Node and Python tools and tests. |

## What you need

- Windows 10 or 11 to use `START.bat`. The apps and tests also run on Linux and macOS with the commands below.
- Git.
- Flutter 3.41.7 (stable channel), with Chrome for the web apps.
- Android Studio (Android SDK) to build the phone app.
- Python 3.11.
- Node.js 20 or newer (24 also works).
- Java 21 or newer, for the Firebase emulators.
- Docker Desktop (optional). Some start options use it for a local mail catcher.

## First-time setup

Run these commands in the repository root.

```
npm ci
python -m pip install -r forecasting/requirements-dev.txt -r platform_service/requirements.txt
cd admin_dashboard
flutter pub get
cd ../flutter_mobile_app
flutter pub get
cd ..
```

Copy `.env.example` to your own environment file only if you need the optional settings in it. Do not commit it.

Check the setup with these two commands. Each one must print only PASS lines. The branch check in the second command fails on any branch other than `Norman`, `main` or `Gestrain`. That failure is expected on other branches.

```
 python scripts/check_no_paid_cloud_defaults.py
 python admin_dashboard/scripts/guard_ai1_constraints.py
```

## Start with no Firebase account

This is the shortest start. It uses only local emulators and fake demo data. It needs no Firebase account, no internet service key and no payment.

1. Finish the first-time setup above.
2. Double-click `START.bat` and choose option **9** (Staff Control Centre with local demo data). When it asks for email domains, press Enter to skip. On Linux or macOS run `node scripts/dev_control_centre.cjs` from the repository root instead.
3. Wait. The first run builds the Control Centre (several minutes), starts the Firebase emulators, and loads the demo companies.
4. The window prints the demo accounts, the sign-in code and the address to open. Open that address in Chrome and sign in.
5. Close the window to stop everything.

To see the company dashboard and the salesperson app with no account, run the end-to-end tests. They build both apps, start the emulators with demo data, and drive the apps in a browser:

```
 npm run e2e:build
 npx playwright-core install chromium
 npm run e2e
```

For one flow only, set `E2E_FILTER` to the flow name (a file in `e2e/flows/`).

Start options 1 to 8 below sign in to the project's real test Firebase projects. They need `dev_accounts.local.json` (copy `dev_accounts.local.example.json` and fill in accounts from your own Firebase project). Use them only when you have those accounts. Do not commit that file.

## Start the apps on your computer

Double-click `START.bat` and choose an option.

| Option | What starts |
|---|---|
| 1 | Admin dashboard, with the forecasting service |
| 2 | Supervisor dashboard, with the forecasting service |
| 3 | Branch manager dashboard, with the forecasting service |
| 4 | Dashboard with the full local stack (mail catcher, one-time-code server, forecasting) |
| 5 | Salesperson app |
| 6 | Dashboard and salesperson app together |
| 7 | Dashboard (full stack) and salesperson app together |
| 8 | Dashboard for the hardware client |
| 9 | Staff Control Centre with local demo data. The window prints the demo accounts and sign-in code. |

Each service opens in its own window. Close the window to stop that service. The start options only use your local computer. They do not deploy anything.

To run one app by hand:

```
cd admin_dashboard
flutter run -d chrome
```

```
cd flutter_mobile_app
flutter run
```

To start the forecasting service by hand:

```
python -m forecasting.service.app
```

To start the website:

```
cd website
npm ci
npm run dev
```

## Run the tests

Run these commands in the repository root.

| What | Command |
|---|---|
| Project checks | `python admin_dashboard/scripts/guard_ai1_constraints.py` and `python scripts/check_no_paid_cloud_defaults.py` |
| Python tests | `python -m pytest` |
| Local server tests | `npm run test:node` |
| Security rules tests (starts the Firestore emulator) | `npm run test:rules:emulator` |
| Dashboard tests | `cd admin_dashboard`, then `flutter test` and `flutter analyze` |
| Phone app tests | `cd flutter_mobile_app`, then `flutter test` and `flutter analyze` |
| End-to-end tests | `npm run e2e:build`, then `npm run e2e` |

The end-to-end tests need Chromium: run `npx playwright-core install chromium` once. All tests run against local emulators and do not touch a live database.

## Build

```
cd admin_dashboard
flutter build web
```

```
cd flutter_mobile_app
flutter build apk --debug --target-platform android-arm64
```

A release build of the phone app needs your own signing key in `flutter_mobile_app/android/key.properties`.

## Install on a server

The files in `deploy/droplet/` install the central service, the Control Centre, the dashboard and the optional assistant server on one Linux server. Start with `deploy/droplet/build-package.sh`. Fill in the settings files that the script names, and keep real keys and passwords out of the repository.

## When something breaks

- A live site or service is down: on the server run `/opt/scoot/bin/scoot-deploy status`. To go back to the previous release, run `/opt/scoot/bin/scoot-deploy rollback --apply`.
- A security problem: use the contact in `website/public/.well-known/security.txt`. The support and security addresses are placeholders until the owner sets real ones.

## Security

Never commit passwords, private keys, service-account files or real sign-in details. Test data and emulator data are for testing only.
