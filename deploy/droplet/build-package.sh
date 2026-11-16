#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
DROPLET_DIR=$ROOT/deploy/droplet
SETTINGS_FILE=$DROPLET_DIR/.env.control
OUT_DIR=$DROPLET_DIR/out
BUILD_NAME=web_control_droplet
DASHBOARD_BUILD_NAME=web_dashboard_droplet
DROPLET_IP=${SCOOT_DROPLET_IP:-146.190.81.250}
CONTROL_HOST=${SCOOT_CONTROL_HOST:-control.scootsales.my}
DASHBOARD_HOST=${SCOOT_DASHBOARD_HOST:-scootsales.my}

die() { printf 'STOP: %s\n' "$*" >&2; exit 1; }

setting() {
  sed -n "s/^$1=//p" "$SETTINGS_FILE" | tail -n 1 | tr -d '\r' | sed -e "s/^['\"]//" -e "s/['\"]\$//"
}

[ -f "$ROOT/platform_service/app.py" ] && [ -f "$ROOT/admin_dashboard/lib/control_centre/main.dart" ] \
  || die "Run this script from a full FYP-A repository checkout."
command -v flutter >/dev/null 2>&1 || die "flutter is not on the PATH."
command -v tar >/dev/null 2>&1 || die "tar is not on the PATH."
PYTHON=$(command -v python3 || command -v python) || die "python is not on the PATH."
"$PYTHON" "$ROOT/scripts/check_deploy_scripts.py" || die "A deploy script does not parse. Fix it before the build."
"$PYTHON" "$ROOT/scripts/check_deploy_package.py" || die "build-package.sh and the dashboard code disagree on the build settings."

if [ ! -f "$SETTINGS_FILE" ]; then
  die "Missing $SETTINGS_FILE. Copy deploy/droplet/env.control.example to deploy/droplet/.env.control and fill it from the Firebase web app settings of the central project."
fi

API_KEY=$(setting STAFF_FIREBASE_API_KEY)
APP_ID=$(setting STAFF_FIREBASE_APP_ID)
PROJECT_ID=$(setting STAFF_FIREBASE_PROJECT_ID)
SENDER_ID=$(setting STAFF_FIREBASE_MESSAGING_SENDER_ID)
AUTH_DOMAIN=$(setting STAFF_FIREBASE_AUTH_DOMAIN)

for name in API_KEY APP_ID PROJECT_ID SENDER_ID; do
  [ -n "${!name}" ] || die "$name is empty in $SETTINGS_FILE."
done
[ -n "$AUTH_DOMAIN" ] || AUTH_DOMAIN=$PROJECT_ID.firebaseapp.com

if grep -q '^PLATFORM_SIGNING_KEY' "$SETTINGS_FILE"; then
  die "$SETTINGS_FILE holds a PLATFORM_SIGNING_KEY line. A private key must never be in a web build. Remove it. Only PLATFORM_PUBLIC_KEYS belongs here."
fi
PUBLIC_KEYS=$(setting PLATFORM_PUBLIC_KEYS)
GEOAPIFY_KEY=$(setting GEOAPIFY_API_KEY)
HIDDEN_DEVELOPER_EMAIL=$(setting HIDDEN_DEVELOPER_EMAIL)
KEY_ENTRY='[a-z0-9][a-z0-9._-]{0,63}=[A-Za-z0-9_-]{43}'
if [ -n "$PUBLIC_KEYS" ] && ! [[ "$PUBLIC_KEYS" =~ ^$KEY_ENTRY(,$KEY_ENTRY)*$ ]]; then
  die "PLATFORM_PUBLIC_KEYS in $SETTINGS_FILE is not in the form keyId=publicKey. Copy the line that 'scoot-deploy public-key' prints."
fi
API_URL=https://$CONTROL_HOST

printf 'Building the Control Centre for Firebase project %s.\n' "$PROJECT_ID"
(
  cd "$ROOT/admin_dashboard"
  flutter build web --release --no-web-resources-cdn -t lib/control_centre/main.dart \
    --output "build/$BUILD_NAME" \
    "--dart-define=STAFF_FIREBASE_API_KEY=$API_KEY" \
    "--dart-define=STAFF_FIREBASE_APP_ID=$APP_ID" \
    "--dart-define=STAFF_FIREBASE_PROJECT_ID=$PROJECT_ID" \
    "--dart-define=STAFF_FIREBASE_MESSAGING_SENDER_ID=$SENDER_ID" \
    "--dart-define=STAFF_FIREBASE_AUTH_DOMAIN=$AUTH_DOMAIN"
)

BUILD_DIR=$ROOT/admin_dashboard/build/$BUILD_NAME
[ -f "$BUILD_DIR/index.html" ] || die "The build did not produce $BUILD_DIR/index.html."
grep -q -F "$PROJECT_ID" "$BUILD_DIR/main.dart.js" || die "The built bundle does not contain the Firebase project ID. The build settings were not applied."
sed -i 's|<title>Scoot Sales</title>|<title>Scoot Sales Control Centre</title>|; s|\(name="apple-mobile-web-app-title" content="\)Scoot Sales"|\1Scoot Sales Control Centre"|' "$BUILD_DIR/index.html"
[ ! -f "$BUILD_DIR/manifest.json" ] || sed -i 's|"name": "Scoot Sales"|"name": "Scoot Sales Control Centre"|; s|"short_name": "Scoot Sales"|"short_name": "Control Centre"|' "$BUILD_DIR/manifest.json"
grep -q -F "<title>Scoot Sales Control Centre</title>" "$BUILD_DIR/index.html" || die "The Control Centre page title was not set."

DASHBOARD_DIR=
HAS_DASHBOARD=no
if [ -n "$PUBLIC_KEYS" ]; then
  printf 'Building the company dashboard for %s.\n' "$API_URL"
  (
    cd "$ROOT/admin_dashboard"
    flutter build web --release --no-web-resources-cdn \
      --output "build/$DASHBOARD_BUILD_NAME" \
      "--dart-define=PLATFORM_API_URL=$API_URL" \
      "--dart-define=PLATFORM_PUBLIC_KEYS=$PUBLIC_KEYS" \
      "--dart-define=GEOAPIFY_API_KEY=$GEOAPIFY_KEY" \
      "--dart-define=HIDDEN_DEVELOPER_EMAIL=$HIDDEN_DEVELOPER_EMAIL"
  )
  DASHBOARD_DIR=$ROOT/admin_dashboard/build/$DASHBOARD_BUILD_NAME
  HAS_DASHBOARD=yes
  [ -f "$DASHBOARD_DIR/index.html" ] || die "The dashboard build did not produce index.html."
  grep -q -F "$API_URL" "$DASHBOARD_DIR/main.dart.js" || die "The dashboard bundle does not contain $API_URL. The build settings were not applied."
  [ -n "$GEOAPIFY_KEY" ] || printf 'WARN: GEOAPIFY_API_KEY is empty in %s. Route Planner shows straight lines and estimates.\n' "$SETTINGS_FILE" >&2
  grep -q -F "$PUBLIC_KEYS" "$DASHBOARD_DIR/main.dart.js" || die "The dashboard bundle does not contain the public key. The build settings were not applied."
else
  printf 'The company dashboard is NOT in this package: PLATFORM_PUBLIC_KEYS is empty in %s.\n' "$SETTINGS_FILE"
fi

STAMP=$(date +%Y%m%d-%H%M%S)
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
PACKAGE=$STAGE/scoot-release
mkdir -p "$PACKAGE/droplet" "$PACKAGE/scripts" "$OUT_DIR"

git -C "$ROOT" ls-files -z -- platform_service | tar --null -C "$ROOT" -T - -cf - | tar -xf - -C "$PACKAGE"
rm -rf "$PACKAGE/platform_service/tests" "$PACKAGE/platform_service/firebase.json" "$PACKAGE/platform_service/firestore.rules"
mkdir -p "$PACKAGE/forecasting"
git -C "$ROOT" ls-files -z -- forecasting/ai_core forecasting/ai_service forecasting/service forecasting/requirements-job.txt forecasting/requirements-ai-runner.txt | tar --null -C "$ROOT" -T - -cf - | tar -xf - -C "$PACKAGE"
rm -rf "$PACKAGE/forecasting/service/tests" "$PACKAGE/forecasting/service/app.py" "$PACKAGE/forecasting/service/auth.py" "$PACKAGE/forecasting/service/excel_importer.py"
mkdir -p "$PACKAGE/admin_dashboard"
cp "$ROOT/admin_dashboard/firestore.rules" "$PACKAGE/admin_dashboard/firestore.rules"
find "$PACKAGE" -name __pycache__ -type d -prune -exec rm -rf {} +
find "$PACKAGE" -name '*.pyc' -delete
cp "$ROOT/scripts/brevo_templates.py" "$PACKAGE/scripts/"
COPILOT_SRC=$ROOT/tools/voice/dashboard_llm
COPILOT_DST=$PACKAGE/tools/voice/dashboard_llm
mkdir -p "$COPILOT_DST/server"
cp "$ROOT/tools/voice/__init__.py" "$PACKAGE/tools/voice/__init__.py"
for file in __init__.py copilot_model.py copilot_schema.py gemini_client.py http_deadline.py; do
  cp "$COPILOT_SRC/$file" "$COPILOT_DST/$file"
done
cp "$COPILOT_SRC/server/__init__.py" "$COPILOT_SRC/server/app.py" "$COPILOT_DST/server/"
cp -r "$BUILD_DIR" "$PACKAGE/web"
if [ -n "$DASHBOARD_DIR" ]; then cp -r "$DASHBOARD_DIR" "$PACKAGE/dashboard"; fi
find "$PACKAGE/web" "$PACKAGE/dashboard" -maxdepth 1 -name workspace.json -delete 2>/dev/null || true
for file in scoot-deploy.sh nginx_site.py check_headers.py scoot-platform.service scoot-scheduler.service platform.env.tpl nginx-control.http.conf.tpl nginx-control.https.conf.tpl scoot-copilot.service copilot.env.tpl scoot-forecast.service scoot-forecast.timer scoot-forecast-hardware.service scoot-forecast-hardware.timer; do
  tr -d '\r' < "$DROPLET_DIR/$file" > "$PACKAGE/droplet/$file"
done
chmod 0755 "$PACKAGE/droplet/scoot-deploy.sh"

COMMIT=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)
DIRTY=$(git -C "$ROOT" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
printf 'id=%s\ncommit=%s\nuncommitted_files=%s\ncontrol_host=%s\ndashboard=%s\n' "$STAMP" "$COMMIT" "$DIRTY" "$CONTROL_HOST" "$HAS_DASHBOARD" > "$PACKAGE/RELEASE"

ARCHIVE_NAME=scoot-control-$STAMP.tar.gz
tar --owner=0 --group=0 -czf "$OUT_DIR/$ARCHIVE_NAME" -C "$STAGE" scoot-release
HASH=$(sha256sum "$OUT_DIR/$ARCHIVE_NAME" | awk '{print $1}')
SIZE=$(du -h "$OUT_DIR/$ARCHIVE_NAME" | awk '{print $1}')

cat <<EOF

Package ready: deploy/droplet/out/$ARCHIVE_NAME ($SIZE)
SHA-256: $HASH
Commit: $COMMIT, uncommitted files: $DIRTY
Control Centre: yes. Company dashboard: $([ -n "$DASHBOARD_DIR" ] && echo yes || echo "no (add PLATFORM_PUBLIC_KEYS to $SETTINGS_FILE and build again)")

Run these commands from the repository root, one at a time.

1. Copy the package to the droplet:
   scp deploy/droplet/out/$ARCHIVE_NAME root@$DROPLET_IP:/root/

2. Unpack it on the droplet:
   ssh root@$DROPLET_IP "rm -rf /root/scoot-release && tar --no-same-owner -xzf /root/$ARCHIVE_NAME -C /root"

3. Dry run. It prints every action and changes nothing:
   ssh -t root@$DROPLET_IP "bash /root/scoot-release/droplet/scoot-deploy.sh"

4. Install for real:
   ssh -t root@$DROPLET_IP "bash /root/scoot-release/droplet/scoot-deploy.sh deploy --apply"

5. Put the new dashboard on scootsales.my. YOUR_COMPANY_CODE is on the company page in the Control Centre; https://scootsales.my opens that company. Dry run first. It finds how the site is served now and prints it:
   ssh -t root@$DROPLET_IP "scoot-deploy dashboard --default-workspace YOUR_COMPANY_CODE"
   Then, when you agree with it (it backs up the nginx file and the web root first):
   ssh -t root@$DROPLET_IP "scoot-deploy dashboard --default-workspace YOUR_COMPANY_CODE --apply"
   To go back:  ssh -t root@$DROPLET_IP "scoot-deploy dashboard-revert --apply"

6. Optional, the Gemini-only Scout service on https://scootsales.my (needs a Gemini API key). Dry run first:
   ssh -t root@$DROPLET_IP "scoot-deploy copilot-install"

7. Tester phone app. Build it with the platform, company lookup and Scout values, or the phone cannot redeem invitations, reset passwords, read its company state or use Scout, and a tester from another company opens the wrong project:
   cd flutter_mobile_app && flutter build apk --release --dart-define PLATFORM_API_URL=$API_URL --dart-define COMPANY_LOOKUP_URL=$API_URL/v1/companies --dart-define COPILOT_URL=https://$DASHBOARD_HOST --dart-define COMPANY_REGISTRY_KEYS=$([ -n "$PUBLIC_KEYS" ] && echo "$PUBLIC_KEYS" || echo "ADD_PLATFORM_PUBLIC_KEYS_TO_$(basename "$SETTINGS_FILE")")
   Keep the APK outside the repository.

Commands 3 and 4 never change scootsales.my or hardware.scootsales.my. Only command 5 does, and it changes only the one dashboard host it names. scootsales.my is the default. For hardware.scootsales.my add  --dashboard-host hardware.scootsales.my  to both the dashboard command and dashboard-revert, and add the code of its company (--default-workspace CODE) to the dashboard command only. The two dashboard hosts must use their own nginx file; the script refuses when one file holds both. Each host has its own link to the dashboard files and its own backup. Only one dashboard action runs at a time.
EOF
